###############################################################################
#    Copyright (c) 2012 VMware, Inc. All Rights Reserved.
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

# @since serengeti 0.5.1
# @version 0.5.1
module Serengeti
  module CloudManager
    class Config
      def_const_value :placement_engine, [{'require' => 'plugin/placement_rr', 'obj' => 'RRPlacement'}]
      def_const_value :res_services,
        [ {'require' => 'plugin/resource_compute', 'obj' => 'ResourceCompute'},
          {'require' => 'plugin/resource_rp'  , 'obj' => 'ResourcePool'},
          {'require' => 'plugin/resource_storage', 'obj' => 'ResourceStorage'},
          {'require' => 'plugin/resource_network', 'obj' => 'ResourceNetwork'}, ]
    end

    class PlacementService < BaseObject
      class PlaceServiceException < PlaceException
      end

      def initialize(cloud)
        @logger = logger
        @rc_services = {}
        @place_engine = cloud.create_service_obj(config.placement_engine.first, cloud) # Currently, we only use the first engine
        raise ParameterException "place engine can not create" if @place_engine.nil?
        load_res_service(cloud, @rc_services)
        @vm_placement = {}
        @vm_placement[:failed_num] = 0
        @vm_placement[:error_msg] = []
        @vm_placement[:place_groups] = []
        @cloud = cloud
      end

      def cloud
        @cloud
      end

      def set_placement_error_msg(msg)
        @vm_placement[:error_msg] << msg
      end

      def check_service(service)
        raise ParameterException "registered service is null" if service.nil?
        raise ParameterException "registered service do not have name" if service.name.to_s.empty?
        raise ParameterException "registered service is existed" if @rc_services.has_key?(service.name)
      end

      def load_res_service(cloud, services)
        res_service = config.res_services
        res_service.each do | service_info |
          service = init_service(cloud.create_service_obj(service_info, cloud))
          services[service.name] = service
        end
      end

      def init_service(service)
        check_service(service)
        service
      end

      def service_loop()
        @rc_services.each_value { |service| yield service }
      end

      # Check resource pools
      def group_placement_rps(dc_res, vm_groups)
        place_rps = []
        vm_groups.each do |vm_group|
          place_rps = vm_group.req_rps.map do |cluster_name, rps|
            rps.map do |rp_name|
              dc_res.clusters[cluster_name].resource_pools[rp_name] if dc_res.clusters.key?(cluster_name)
            end
          end
        end
        place_rps = place_rps.flatten.compact
        if place_rps.nil? || place_rps.size == 0
          @vm_placement[:failed_num] += 1
          err_msg = "Can not get any resource pools for vm"
          @logger.error(err_msg)
          set_placement_error_msg(err_msg)
          return nil
        end
        place_rps
      end

      def create_vm_with_each_resource(vm_spec_groups)
        vmServersGroup = []
        vm_spec_groups.each do |vm_spec_group|
          vm = VmServer.new
          service_loop { |service| vm.init_with_vm_service(service, vm_spec_group) }
          vmServersGroup << {:vm => vm, :specs => vm_spec_group}
        end
        vmServersGroup
      end

      def scores2_host(scores)
        scores_host = {}
        scores.each do |name, score|
          score.each do |host, value|
            scores_host[host] = {} if scores_host[host].nil?
            scores_host[host][name] = value
          end
        end
        scores_host
      end

      def place_group_vms_with_rp(place_rps, vm_group, group_place, existed_vms, placed_vms)
        # Get all hosts with paired info
        hosts = place_rps.map { |rp| rp.cluster.hosts.values.map { |h| h.name } }.flatten
        # hosts' info is [hostname1, hostname2, ... ]

        # Return such like this [[vmSpec1, vmSpec2],[vmSpec3]] 
        virtual_nodes = @place_engine.get_virtual_nodes(vm_group, existed_vms, placed_vms)

        # Return such like this [[vmServer1, vmServer2],[vmServer3]]
        #@logger.debug("vns:#{virtual_nodes.pretty_inspect}")
        specs = virtual_nodes.map { |node| node.map { |spec| spec.to_spec} }
        #@logger.debug("vns->specs#{specs.pretty_inspect}")
        vmServersGroups = create_vm_with_each_resource(specs)

        vmServersGroups.each do |group|
          # Check capacity
          service_loop do |service|
            hosts = service.check_capacity(group[:vm], hosts)
            raise PlaceServiceException,'Do not find hosts can match resources requirement' if hosts.nil?
          end

          # Each service calc their values
          scores = {}
          service_loop do |service|
            # Return value is {host1=>value1, host2=>value2}
            scores[service.name] = service.evaluate_hosts(group[:vm], hosts)
          end

          #logger.debug("scores: #{scores.pretty_inspect}")
          scores_host = scores2_host(scores)
          logger.debug("scores_host: #{scores_host.keys.pretty_inspect}")
          # place engine to decide how to place
          success = true
          selected_host = nil
          loop do
            selected_host = @place_engine.select_host(group[:specs], scores_host)
            raise PlaceServiceException,'Do not select suitable host' if selected_host.nil?

            committed_service = []
            service_loop do |service|
              success = service.commit(scores[service.name][selected_host])
              if success
                committed_service.unshift(group[:vm], service)
              else
                # Dis Commit
                success = false
                committed_service.each { |plug| service.discommit(scores[service.name][selected_host]) }
                @logger.debug("VM commit is failed.")
                break
              end
            end
            break if success
            scores_host.delete(selected_host)
            break if scores_host.empty?
          end

          if success
            logger.debug("assign to #{selected_host}")
            @place_engine.assign_host(group[:specs], selected_host)
            group_place << group
          end
        end
        group_place.flatten
      end

      def cluster_placement(dc_resource, vm_groups_input, vm_groups_existed)
        @vm_placement[:failed_num] = 0
        @vm_placement[:error_msg] = []
        @vm_placement[:place_groups] = []
 
        info = { :dc_resource => dc_resource, :vm_groups => vm_groups_input, :place_service => self }
        service_loop { |service| service.init_self(info) }

        @place_engine.placement_init(self, dc_resource)
        virtual_groups = @place_engine.get_virtual_groups(vm_groups_input)

        virtual_groups.each_value do |virtual_group|
          # check information and check error
          group_place   = []
          place_err_msg = nil
          # Group's Resource pool check.
          place_rps = group_placement_rps(dc_resource, virtual_group.to_vm_groups)
          next if place_rps.nil?
          @logger.debug("place_rps: #{place_rps.pretty_inspect}")

          begin
            place_group_vms_with_rp(place_rps, virtual_group, group_place,
                                    cloud.state_sub_vms(:existed),
                                    cloud.state_sub_vms(:placed))
          rescue PlaceServiceException => e
            ## can not alloc virual_group anymore
            set_placement_error_msg("Can not alloc resource for vm group #{virtual_group.name}: #{place_err_msg}")
            @vm_placement[:failed_num] += 1
            @logger.error("VM group #{virtual_group.name} failed to place vm, "\
                          "total failed: #{@vm_placement[:failed_num]}.") if config.debug_placement
            next
          end
          @vm_placement[:place_groups] << group_place
        end
        @vm_placement
      end
    end

  end
end
