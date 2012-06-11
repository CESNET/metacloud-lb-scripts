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

require 'lumberjack_syslog_device'

class SyslogService

  def initialize(notifier_name = "OpenNebulaSyslogNotifier")
    @logger = Lumberjack::Logger.new(Lumberjack::SyslogDevice.new)
    @logger.progname = notifier_name
  end

  def write(message)
    @logger.info message
  end

end
