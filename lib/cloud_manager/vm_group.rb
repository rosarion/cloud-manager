###############################################################################
#   Copyright (c) 2012 VMware, Inc. All Rights Reserved.
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
################################################################################

# @version 0.5.0

module Serengeti
  module CloudManager

    class Cloud
      def cluster_datastore_pattern(cluster_info, type)
        if type == 'shared'
          return cluster_info["vc_shared_datastore_pattern"]
        elsif type == 'local'
          return cluster_info["vc_local_datastore_pattern"]
        end
        nil
      end

      # fetch vm_group information from user input (cluster_info)
      # It will assign template/rps/networking/datastores info to each vm group
      # Return: the vm_group structure
      def create_vm_group_from_input(cluster_info, datacenter_name)
        vm_groups = {}
        #logger.debug("cluster_info: #{cluster_info.pretty_inspect}")
        input_groups = cluster_info["groups"]
        return nil if input_groups.nil?
        template_id = cluster_info["template_id"] #currently, it is mob_ref
        raise "template_id should a vm mob id (like vm-1234)." if /^vm-[\d]+$/.match(template_id).nil?
        cluster_req_rps = @vc_req_rps
        cluster_req_rps = req_clusters_rp_to_hash(cluster_info["vc_clusters"]) if cluster_info["vc_clusters"]
        cluster_networking = cluster_info["networking"]
        logger.debug("networking : #{cluster_networking.pretty_inspect}") if config.debug_networking

        network_res = NetworkRes.new(cluster_networking)
        #logger.debug("dump network:#{network_res}")
        logger.debug("template_id:#{template_id}")
        input_groups.each do |vm_group_req|
          vm_group = VmGroupInfo.new(vm_group_req)
          vm_group.req_info.template_id ||= template_id
          disk_pattern = vm_group.req_info.disk_pattern || cluster_datastore_pattern(cluster_info, vm_group.req_info.disk_type)
          logger.debug("vm_group disk patterns:#{disk_pattern.pretty_inspect}") if config.debug_placement_datastore

          vm_group.req_info.disk_pattern = []
          disk_pattern = ['*'] if disk_pattern.nil?
          vm_group.req_info.disk_pattern = change_wildcard2regex(disk_pattern).map { |x| Regexp.new(x) }
          logger.debug("vm_group disk ex patterns:#{vm_group.req_info.disk_pattern.pretty_inspect}")  if config.debug_placement_datastore

          vm_group.req_rps = (vm_group_req["vc_clusters"].nil?) ? cluster_req_rps : req_clusters_rp_to_hash(vm_group_req["vc_clusters"])
          vm_group.network_res = network_res
          vm_groups[vm_group.name] = vm_group
        end
        #logger.debug("input_group:#{vm_groups}")
        vm_groups
      end

      # fetch vm_group information from dc resources came from vSphere (dc_res)
      # It will assign existed vm to each vm group, and put them to VM_STATE_READY status.
      # Return: the vm_group structure
      def create_vm_group_from_resources(dc_res)
        vm_groups = {}
        dc_res.clusters.each_value do |cluster|
          cluster.hosts.each_value do |host|
            host.vms.each_value do |vm|
              logger.debug("vm :#{vm.name}")

              result = parse_vm_from_name(vm.name)
              next unless result
              cluster_name = result["cluster_name"]
              group_name = result["group_name"]
              num = result["num"]
              next if (cluster_name != config.cloud_cluster_name)

              sync_vhm_info(vm)
              vm_group = vm_groups[group_name]
              if vm_group.nil?
                # Create new Group
                vm_group = VmGroupInfo.new()
                vm_group.name = group_name
                vm_groups[group_name] = vm_group
              end
              # Update existed vm info
              vm.status = VmInfo::VM_STATE_READY
              vm.action = VmInfo::VM_ACTION_START # existed VM action is VM_ACTION_START
              logger.debug("Add #{vm.name} to existed vm")
              vm_group.add_vm(vm)
              @vm_lock.synchronize { state_sub_vms(:existed)[vm.name] = vm }
            end
          end
        end
        #logger.debug("res_group:#{vm_groups}")
        vm_groups
      end

      def sync_vhm_info(vm)
        if config.vhm_masterVM_uuid == '' || config.vhm_masterVM_moid == ''
          config.vhm_masterVM_uuid = get_value(vm.extra_config, "vhmInfo.masterVM.uuid")
          config.vhm_masterVM_moid = get_value(vm.extra_config, "vhmInfo.masterVM.moid")
        end
      end

      def get_value(prop, key)
        prop.each do |entry|
          if entry[:key] == key
            return entry[:value]
          end
        end
        return ''
      end
    end

    DISK_TYPE_SHARE = 'shared'
    DISK_TYPE_LOCAL = 'local'
    DISK_TYPE_TEMP  = 'tempfs'
    DISK_TYPE = [DISK_TYPE_SHARE, DISK_TYPE_LOCAL, DISK_TYPE_TEMP]
    class ResourceInfo
      DISK_SIZE_UNIT_CONVERTER = 1024
      attr_accessor :cpu
      attr_accessor :mem
      attr_accessor :disk_type
      attr_accessor :disk_size
      attr_accessor :disk_pattern
      attr_accessor :rack_id
      attr_accessor :template_id
      attr_accessor :ha
      attr_accessor :vm_folder_path
      attr_accessor :disk_bisect
      attr_accessor :elastic

      def initialize(rp=nil)
        if rp
          @cpu = rp["cpu"] || 1
          @mem = rp["memory"] || 512
          @disk_size =  rp["storage"]["size"] || 0
          @disk_pattern = rp["storage"]["name_pattern"]
          @disk_size *= DISK_SIZE_UNIT_CONVERTER
          @disk_type = rp["storage"]["type"]
          @disk_type = DISK_TYPE_SHARE if !DISK_TYPE.include?(@disk_type)
          @template_id = rp["template_id"]
          @ha = rp["ha"] #Maybe 'on' 'off' 'ft'
          @ha = 'off' if rp["ha"].nil?
          @rack_id = nil
          @vm_folder_path = rp["vm_folder_path"]
          @disk_bisect = rp["storage"]["bisect"] || false

          # generally, cloud-manager is supposed to be not aware of group roles, here is really an exception case
          roles = rp["roles"]
          if roles.size == 1 && roles.include?("hadoop_tasktracker")
            @elastic = true
          else
            @elastic = false
          end
          # set config.serengeti_uuid when first meet "vm_folder_path"
          config.serengeti_uuid = rp["vm_folder_path"].split(/\//)[0] if config.serengeti_uuid == ''
        end
      end

      def config
        Serengeti::CloudManager.config
      end

    end

    class VmGroupRack
      attr_accessor :type
      attr_accessor :racks
      include Serengeti::CloudManager::Utils

      SAMERACK = "samerack"
      ROUNDROBIN = "roundrobin"
      SUPPROT_RACK_TYPE = [SAMERACK, ROUNDROBIN]
      def initialize(options = {})
        @type   = options["type"].downcase
        raise Serengeti::CloudManager::PlacementException,\
          "Do not support this rack type:#{options["type"]}." if !SUPPROT_RACK_TYPE.include?(@type)

        @racks  = []
        racks = options["racks"]
        racks = config.cloud_rack_to_hosts.keys if racks.nil? or racks.empty?
        racks_used = racks & config.cloud_rack_to_hosts.keys
        racks_diff = racks - config.cloud_rack_to_hosts.keys
        logger.warn("rack [#{racks_diff}] not in cluster rack info.") if !racks_diff.empty? 
        raise Serengeti::CloudManager::PlacementException,\
          "#{racks} do not in cluster definition." if racks_used.empty?
        raise Serengeti::CloudManager::PlacementException,\
          "More than one rack #{racks} in SameRack option." if racks_used.size > 1 and @type == SAMERACK
        @racks = racks_used
        logger.debug("group rack: #{racks} used: #{racks_used} diff: #{racks_diff} ")
      end
    end

    class VmGroupAssociation
      attr_accessor :referred_group
      attr_accessor :associate_type
      ASSOC_STRICT = "STRICT"

      def initialize(options = {})
        @referred_group = options["reference"] if options["reference"]
        @associate_type = options["type"] if options["type"]
      end
    end

    class VmGroupPlacementPolicy
      attr_accessor :instance_per_host
      attr_accessor :group_associations
      attr_accessor :group_racks

      include Serengeti::CloudManager::Utils
      def initialize(options = {})
        @instance_per_host = options["instance_per_host"] if options["instance_per_host"]
        @group_associations = []
        if options["group_associations"]
          options["group_associations"].each do |asn_hash|
            @group_associations << VmGroupAssociation.new(asn_hash)
          end
        end
        if !config.cloud_rack_to_hosts.empty? && options["group_racks"]
          @group_racks = VmGroupRack.new(options["group_racks"])
        end
      end
    end

    # This structure contains the group information
    class VmGroupInfo
      attr_accessor :name       #Group name
      attr_accessor :req_info   #class ResourceInfo
      attr_reader   :vc_req
      attr_accessor :instances  #wanted number of instance
      attr_accessor :req_rps
      attr_accessor :network_res
      attr_accessor :vm_ids    #classes VmInfo
      attr_accessor :placement_policies
      attr_accessor :created_num

      include Serengeti::CloudManager::Utils
      def initialize(rp=nil)
        @vm_ids = {}
        @req_info = ResourceInfo.new(rp)
        @name = ""
        return unless rp
        @name = rp["name"]
        @instances = rp["instance_num"]
        @req_rps = {}
        @created_num = nil
        @placement_policies = nil
        if rp["placement_policies"]
          @placement_policies = VmGroupPlacementPolicy.new(rp["placement_policies"])
        end
      end

      def rack_policy
        return nil if @placement_policies.nil?
        return nil if @placement_policies.group_racks.nil?
        @placement_policies.group_racks
      end

      def to_vm_groups
        [self]
      end

      def to_spec
        {
          'vm_group_name' => name,
          'template_id' => req_info.template_id,

          'req_mem' => req_info.mem,
          'cpu' => req_info.cpu,
          'ha' => req_info.ha,

          'datastore_pattern' => req_info.disk_pattern,
          'data_size' => (req_info.disk_type == DISK_TYPE_TEMP) ? 0 : req_info.disk_size,
          'data_shared' => (req_info.disk_type == DISK_TYPE_SHARE),
          'data_mode' => 'thick_egger_zeroed',
          'data_affinity' => 'split',
          'disk_bisect' => req_info.disk_bisect,

          'system_size' => config.vm_sys_disk_size,
          'system_shared' => ((req_info.disk_type == DISK_TYPE_SHARE and req_info.disk_type != DISK_TYPE_TEMP) \
                              || (req_info.disk_type == DISK_TYPE_TEMP and !config.cluster_has_local_datastores)),
          'system_mode' => 'thin',
          'system_affinity' => nil,

          'port_groups' => network_res.port_groups,
          'vm_folder_path' => req_info.vm_folder_path,
          'elastic' => req_info.elastic
        }
      end

      def size
        vm_ids.size
      end

      def del_vm(vm_name)
        vm_info = find_vm(vm_name)
        return nil unless vm_info
        vm_info.delete_all_disk

        @vm_ids.delete(vm_mob)
      end

      def add_vm(vm_info)
        if @vm_ids[vm_info.name].nil?
          @vm_ids[vm_info.name] = vm_info
        else
          logger.debug("#{vm_info.name} is existed.")
        end
      end

      def find_vm(vm_name)
        @vm_ids[vm_name]
      end

      def instance_per_host
        return nil if @placement_policies.nil?
        return @placement_policies.instance_per_host
      end

      # does not support reference to multi-groups right now
      def referred_group
        return nil if @placement_policies.nil? or @placement_policies.group_associations.size == 0
        return @placement_policies.group_associations[0].referred_group
      end

      def associate_type
        return nil if @placement_policies.nil? or @placement_policies.group_associations.size == 0
        return @placement_policies.group_associations[0].associate_type
      end

      def is_strict?
        associate_type == VmGroupAssociation::ASSOC_STRICT
      end

    end

  end
end

