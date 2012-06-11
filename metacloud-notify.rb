#!/usr/bin/env ruby

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

$: << File.expand_path("..", __FILE__) + '/lib'

require 'notifier'
require 'optparse_notifier'
require 'log4r'

include Log4r

options = OptparseNotifier.parse(ARGV)

logger = Logger.new 'MetaCloudNotifier'
logger.outputters = Outputter.stderr
logger.level = ERROR unless options.debug

notifier = Notifier.new(options.service, logger)

vm_template_xml = notifier.decode_base64 options.vm_template
vm_info = notifier.read_template vm_template_xml

notifier.notify "Hello, I'm a Syslog Notifier for OpenNebula. There is something going on with #{vm_info.NAME}."
