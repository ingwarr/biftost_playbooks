#!/bin/bash -ex

function waitForSSH {
  local server_ip="$1"
  local BOOT_TIMEOUT=180
  local CHECK_TIMEOUT=30
  local cur_time=0

  LOG_FINISHED="1"
  while [[ "${LOG_FINISHED}" == "1" ]]; do
    sleep $CHECK_TIMEOUT
    time=$(($cur_time+$CHECK_TIMEOUT))
    LOG_FINISHED=$(nc -w 2 $server_ip 22; echo $?)
    if [ ${cur_time} -ge $BOOT_TIMEOUT ]; then
      echo "Can't get to VM in $BOOT_TIMEOUT sec"
      exit 1
    fi
  done
}

export ANSIBLE_HOST_KEY_CHECKING=False
ssh_opts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"

if [[ "$DISTRO_RELEASE" == "ubuntu-xenial" ]]; then
    SRC_VM='generic_bifrost '
else
    SRC_VM="generic_bifrost-$DISTRO_RELEASE"
fi
ENV_NAME=${BUILD_USER_ID}-${DEP_NAME}

virt-clone --connect=qemu:///system -o ${SRC_VM} -n ${ENV_NAME} --auto-clone
VM_MAC=`virsh domiflist ${ENV_NAME} | grep devstack-net | awk '{print $5}'`
virsh start ${ENV_NAME}
sleep 120
VM_IP=`/usr/sbin/arp -an  |grep "${VM_MAC}" | grep -o -P '(?<=\? \().*(?=\) .*)'`
sshpass -p r00tme ssh ${ssh_opts} root@${VM_IP} "echo $ENV_NAME > /etc/hostname; sed -i "s/ub16-standard/$ENV_NAME/g" /etc/hosts; hostname $ENV_NAME; (sleep 1; reboot) &"
waitForSSH ${VM_IP}

#TODO clone empty VM and generate yaml for it(for case w/o hardware servers) and operations with downstream bifrost
cp -r /tmp/biftost_playbooks/custom_inventory ~jenkins/workspace/bifrost_remote/playbooks/
cd ~jenkins/workspace/bifrost_remote/playbooks/
sed -i "s/10.20.0/192.168.10/g" install-target.yaml
echo "[target]
${VM_IP} ansible_connection=ssh ansible_user=ingwarr ansible_ssh_pass=ytpfvfq! ansible_become_pass=ingwarr" > ./custom_inventory/target
env
pwd
whoami
ansible-playbook -vvvv -i custom_inventory/target install-target.yaml
