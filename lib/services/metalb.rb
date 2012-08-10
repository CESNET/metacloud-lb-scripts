# -------------------------------------------------------------------------- #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'erb'
require 'open3'
require 'sequel'
require 'resolv'
require 'chronic_duration'
require 'timeout'
require 'date'

require 'notifier_error'

class MetalbService

  attr_reader :logger
  attr_reader :notifier_name

  SHELL_CMD_TIMEOUT = 10
  SHELL_CMD_TIMEOUT_LONG = SHELL_CMD_TIMEOUT * 2
  PROXY_REINIT_DEADLINE = 60

  def initialize(notifier_name, logger)
    
    @notifier_name = notifier_name ||  "OpenNebulaMetaLBNotifier"

    @logger = logger

    # we need a DB for VMID <-> JOBID mappings
    unless ENV['ONE_LOCATION'].empty?
      @db = Sequel.sqlite "#{ENV['ONE_LOCATION']}/db/metacloud-notify.sqlite"
    else  
      @db = Sequel.sqlite 'metacloud-notify.sqlite'
    end

    # create lb_jobs table if there isn't one already available
    unless @db.tables.include? :lb_jobs
     @db.create_table :lb_jobs do
        primary_key :vmid
        String :lbjobid, :unique => true, :null => false
        DateTime :created_at
      end
    end
  end

  def write(message)

    # check credentials
    initGlobusProxy unless validGlobusProxy

    @logger.debug "[#{@notifier_name}] writting:\n#{message}" unless @logger.nil?

    cmd_out = nil
    cmd_err_out = nil
    exit_status = nil

    begin
      Timeout::timeout(SHELL_CMD_TIMEOUT_LONG){
        # message for LB is a shell command, we have to run it
        stdin, stdout, stderr, wait_thr = Open3.popen3(message)

        # get the response from stdout and insert a new mapping if this was job_reg
        cmd_out = stdout.read.strip 

        # make sure that everything went as expected
        cmd_err_out = stderr.read
        exit_status = wait_thr.value

        # clean-up
        stdin.close
        stdout.close
        stderr.close
      }
    rescue Timeout::Error => timex
      @logger.error "[#{@notifier_name}] globus-proxy timed out!" unless @logger.nil?
      raise NotifierError, "Failed to send the message! Timeout."
    end  

    @logger.debug "[#{@notifier_name}] PID: #{exit_status.pid}" unless @logger.nil?
    @logger.debug "[#{@notifier_name}] STDOUT:\n#{cmd_out}" unless @logger.nil?
    @logger.debug "[#{@notifier_name}] STDERR:\n#{cmd_err_out}" unless @logger.nil?
    @logger.debug "[#{@notifier_name}] STATUS: #{exit_status.exitstatus}" unless @logger.nil?

    if @current_state == :create
      raise NotifierError, "glite-lb-job_reg returned invalid JOB ID. [#{cmd_out}]" unless cmd_out.start_with? "https://"
      putMapping(@current_vmid, cmd_out)
    end

    # if something went wrong, report it
    if exit_status.exitstatus > 0
      @logger.error "[#{@notifier_name}] #{cmd_err_out}" unless @logger.nil?
    end

    # DONE is the last state, DB clean-up
    delMapping(@current_vmid) if @current_state == :done

    exit_status.exitstatus

  end

  def prepare_message(vm_state, user_identity, vm_template, vm_usage)

    # store some variables in attributes for subsequent use in write
    @current_vmid = vm_template.ID
    @current_state = vm_state

    # resolv the first VM IP address to a hostname
    vm_hostname = 'UNKNOWN'
    
    begin
      vm_hostname = Resolv.getname(vm_template.IPS.first) unless vm_template.IPS.nil?
    rescue
      @logger.error "[#{@notifier_name}] couldn't resolve #{vm_template.IPS.first} to a valid hostname" unless @logger.nil?
    end

    # get vm -> lbjob mapping if there is one
    edg_jobid = getMapping(@current_vmid)
    edg_jobid = "" if edg_jobid.nil?    
    
    # TODO do we need dynamic sequences?
    edg_wl_sequence="UI=000000:NS=0000000000:WM=000000:BH=0000000000:JSS=000000:LM=000000:LRMS=000000:APP=000000:LBS=000000"

    # use templates to generate the message
    msg_template = ERB.new File.new(File.expand_path("..", __FILE__) + "/templates/metalb.erb").read
    message = msg_template.result(binding)

    @logger.debug "[#{@notifier_name}] constructed:\n#{message}" unless @logger.nil?

    message

  end

  def putMapping(vmid, jobid)

    @logger.debug "[#{@notifier_name}] inserting a mapping #{vmid} -> #{jobid}" unless @logger.nil?
    @db[:lb_jobs].insert(:vmid => vmid, :lbjobid => jobid, :created_at => DateTime.now)

  end

  def getMapping(vmid)
    
    ds = @db[:lb_jobs].where(:vmid => vmid)

    if ds.count == 1

      @logger.debug "[#{@notifier_name}] found a mapping #{vmid} -> #{ds.first[:lbjobid]}" unless @logger.nil? 
      ds.first[:lbjobid]

    else
      nil
    end

  end

  def delMapping(vmid)

    @logger.debug "[#{@notifier_name}] deleting a mapping for #{vmid}" unless @logger.nil?
    @db[:lb_jobs].filter(:vmid => vmid).delete

  end

  ## TODO clean-up, refactor proxy methods  ##

  def validGlobusProxy

    @logger.debug "[#{@notifier_name}] checking globus-proxy" unless @logger.nil?
    proxy_info = "grid-proxy-info | grep 'timeleft' | awk -F ' : ' '{print $2}'"
    
    # default to non-valid
    status = false

    wait_thr = nil
    valid_for = nil

    begin
      Timeout::timeout(SHELL_CMD_TIMEOUT){
        stdin, stdout, stderr, wait_thr = Open3.popen3(proxy_info)

        valid_for = stdout.read

        stdin.close
        stdout.close
        stderr.close
      }
    rescue Timeout::Error => timex
      @logger.error "[#{@notifier_name}] globus-proxy timed out!" unless @logger.nil?
      return status
    end
    
    if wait_thr.value.exitstatus == 0 and not valid_for.empty?
      @logger.debug "[#{@notifier_name}] globus-proxy is valid for another #{valid_for}" unless @logger.nil?
      status = true
      
      parsed_valid_for = ChronicDuration::parse(valid_for)
      status = false if parsed_valid_for.nil? or parsed_valid_for < PROXY_REINIT_DEADLINE
    end

    status

  end

  def initGlobusProxy

    @logger.debug "[#{@notifier_name}] starting globus-proxy" unless @logger.nil?
    proxy_init = "grid-proxy-init"

    wait_thr = nil
    err_out = nil

    begin
      Timeout::timeout(SHELL_CMD_TIMEOUT){
        stdin, stdout, stderr, wait_thr = Open3.popen3(proxy_init)

        err_out = stderr.read

        stdin.close
        stdout.close
        stderr.close
      }
    rescue Timeout::Error => timex
      @logger.error "[#{@notifier_name}] globus-proxy timed out!" unless @logger.nil?
      raise NotifierError, "Failed to initialize globus-proxy! Timeout."
    end
    
    unless wait_thr.value.exitstatus == 0
      @logger.error "[#{@notifier_name}] globus-proxy-init failed with #{err_out}" unless @logger.nil?
      raise NotifierError, "Failed to initialize globus-proxy! #{err_out}"
    end

  end

  def destroyGlobusProxy

    proxy_destroy = "grid-proxy-destroy"

    begin
      Timeout::timeout(SHELL_CMD_TIMEOUT){
        stdin, stdout, stderr, wait_thr = Open3.popen3(proxy_destroy)

        stdin.close
        stdout.close
        stderr.close
      }
    rescue Timeout::Error => timex
      @logger.error "[#{@notifier_name}] globus-proxy timed out!" unless @logger.nil?
    end

  end

end
