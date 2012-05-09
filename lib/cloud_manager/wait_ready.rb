module VHelper::CloudManager
  class VHelperCloud
    def cluster_wait_ready(vm_pool)
      @logger.debug("wait all existed vms poweron and return their ip address")
      group_each_by_threads(vm_pool) { |vm|
        @logger.debug("vm:#{vm.name} can ha?:#{vm.can_ha}, enable ? #{vm.ha_enable}")
        if !vm.ha_enable && vm.can_ha?
          next if !vm_deploy_op(vm, 'disable ha') { @client.vm_set_ha(vm, vm.ha_enable)}
          @logger.debug("disable ha of vm #{vm.name}")
        elsif (!vm.can_ha? && vm.ha_enable)
          #TODO add error msg to cluster error message
          @logger.debug("can not enable ha on unHA cluster")
        end

        # Power On vm
        vm.status = VM_STATE_POWER_ON
        @logger.debug("vm:#{vm.name} power:#{vm.power_state}")
        if vm.power_state == 'poweredOff'
          next if !vm_deploy_op(vm, 'power on') { vm_poweron(vm)}
          @logger.debug("#{vm.name} has poweron")
        end
        vm.status = VM_STATE_WAIT_IP

        next if !vm_deploy_op(vm, 'wait ip') {
          while (vm.ip_address.nil? || vm.ip_address.empty?)
            @client.update_vm_properties_by_vm_mob(vm)
            @logger.debug("#{vm.name} ip: #{vm.ip_address}")
            sleep(4)
          end
        }

        #TODO add ping progress to tested target vm is working
        vm.status = VM_STATE_DONE
        vm_finish(vm)
        @logger.debug("#{vm.name}: done")
      }
      @logger.info("Finish all waiting")
      "finished"
    end
  end
end
