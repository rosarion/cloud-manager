module Serengeti; end
require "rubygems"
require "tmpdir"
require 'openssl'
require 'tempfile'
require 'yaml'
require 'erb'
require 'pp'

require './spec/config'
require 'cloud_manager'
require './spec/fog_dummy'

WDC_CONFIG_FILE = "./spec/ut.wdc.yaml"
VC_CONFIG_FILE = "./spec/ut.vc.yaml"
WDC_DEF_CONFIG_FILE_1 = "./spec/ut.wdc_def.yaml"
DC_DEF_CONFIG_FILE_1 = "./spec/ut.dc_def1.yaml"
DC_DEF_CONFIG_FILE_2 = "./spec/ut.dc_def2.yaml"

def ut_test_env
  info = {}
  vcenter = YAML.load(File.open(VC_CONFIG_FILE))
  cluster_req_1 = YAML.load(File.open(DC_DEF_CONFIG_FILE_1))
  info["cluster_definition"] = cluster_req_1
  info["cloud_provider"] = vcenter
  info['type'] = 'UT'
  puts("cluster_def : #{cluster_req_1}")
  puts("provider: #{vcenter}")
  info
end

def wdc_test_env
  info = {}
  vcenter = YAML.load(File.open(WDC_CONFIG_FILE))
  cluster_req_1 = YAML.load(File.open(WDC_DEF_CONFIG_FILE_1))
  info["cluster_definition"] = cluster_req_1
  info["cloud_provider"] = vcenter
  info['type'] = 'WDC'
  puts("cluster_def : #{cluster_req_1}")
  puts("provider: #{vcenter}")
  info
end

def print_parameter(wait, info, log_level)
  puts "Please select"
  puts "\t1-->UT env \t2-->WDC env \tcurrent:#{info['type']}"
  puts "\t3-->wait (current:#{wait})"
  puts "\t4-->set log level (current:#{log_level})"
  puts "\t"

  puts "\t5-->Create cluster\n"
  puts "\t6-->Delete cluster\n"
  puts "\t7-->List all cluster\n"
  puts "\t8-->start all vm in cluster\n"
  puts "\t9-->stop all vm in cluster\n"
  puts "\t10-->exited test\n"
  puts "\t100 --> auto testing for all known cases (not finish)"

end

begin
  wait = true
  info = wdc_test_env
  log_level = 'debug'
  while (true)
    print_parameter(wait, info, log_level)
    begin
      opt = gets.chomp
      opt = opt.to_i
      puts "You select #{opt}"
      case opt
      when 1 then
        p "##Select UT env"
        info = ut_test_env
      when 2 then
        p "##Select WDC env"
        info = wdc_test_env
      when 3 then
        wait = !wait
        p "set wait to #{wait}"
      when 4 then
        p "Please input log level"
        opt = gets.chomp.to_s
        Serengeti::CloudManager::Manager.set_log_level(opt)
        log_level = opt


      when 5 then
        p "##Create cluster"
        cloud = Serengeti::CloudManager::Manager.create_cluster(info, :wait => wait)
        while !cloud.finished?
          progress = cloud.get_progress
          puts("ut process:#{progress.inspect}")
          sleep(1)
        end
        puts("UT finished")
        progress = cloud.get_progress
        puts("ut process:#{progress.inspect}")

      when 6 then #Delete Cluster
        puts "## Delete Cluster in UT"
        cloud = Serengeti::CloudManager::Manager.delete_cluster(info, :wait => wait)
        while !cloud.finished?
          puts("delete ut process:#{cloud.get_progress}")
          sleep(1)
        end
        puts("UT finished")
        progress = cloud.get_progress
        puts("ut process:#{progress.inspect}")

      when 7 then #List vms in Cluster
        puts("##List all vm in UT")
        result = Serengeti::CloudManager::Manager.list_vms_cluster(info)
        puts("##result:#{result.pretty_inspect}")

      when 8 then #Start vms in Cluster
        puts("##List all vms")
        result = Serengeti::CloudManager::Manager.start_cluster(info, :wait => wait)
        progress = result.get_progress
        puts("ut process:#{progress.inspect}")

      when 9 then #Stop vms in Cluster
        puts("##List all vms")
        result = Serengeti::CloudManager::Manager.stop_cluster(info, :wait => wait)
        progress = result.get_progress
        puts("##result:#{progress.inspect}")

      when 10 then
        puts ("Finish testing")
        break

      else
        puts("Unknow test case!\n")
      end
    rescue => e
      puts("#{e} - #{e.backtrace.join("\n")}")
      break
    end
  end
end
