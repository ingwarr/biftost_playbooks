#!/bin/bash -ex

function netCreate {
    local net_name="$1"
    local net_prefix="$2"
    local choose_range=50
    local net_start=10
    empty_net=0
    while [ ${empty_net} -eq 0 ]
        do
	    echo "${net_prefix}.${net_start}"
            e_nets=`ifconfig|grep "${net_prefix}.${net_start}"|wc -l`
            if [ ${e_nets} -ge 1 ]
                then
                    let "net_start += 1"
                else
                    empty_net=1
            fi
        done
    echo "<network>
  <name>${net_name}</name>
  <bridge name=\"${net_name}\"/>
  <forward/>
  <ip address=\"${net_prefix}.${net_start}.1\" netmask=\"255.255.255.0\">
  </ip>
</network>" > /tmp/bmnet.xml
    virsh net-create /tmp/bmnet.xml
}

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

PS_BM_NUM=3
export ANSIBLE_HOST_KEY_CHECKING=False
ssh_opts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"
BM_NET_NAME="hw_bifrost"
VM_USER="stack"
VM_PASS=`pwgen -s 12 1`
VM_USER_SHELL="/bin/bash"

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
sshpass -p r00tme ssh ${ssh_opts} root@${VM_IP} "echo $ENV_NAME > /etc/hostname; sed -i "s/ub16-standard/$ENV_NAME/g" /etc/hosts; hostname $ENV_NAME; useradd -m -G sudo --shell ${VM_USER_SHELL} ${VM_USER}; echo -e \"${VM_PASS}\n${VM_PASS}\n\" | passwd ${VM_USER};  (sleep 1; reboot) &"
waitForSSH ${VM_IP}
#TODO clone empty VM and generate yaml for it(for case w/o hardware servers) and operations with downstream bifrost
echo -e "---\n" > /tmp/baremetal.yml
if [ ${hw_enabled} == "false" ]
    then
        for i in `seq ${PS_BM_NUM}`
            do
                PS_BM_NAME=`virt-clone -o ps_bm --auto-clone|awk '/Clone/ {print $2}'|awk -F"'" '{print $2}'`
		PS_BM_MAC=`virsh domiflist ${PS_BM_NAME} | grep ${BM_NET_NAME} | awk '{print $5}'`
		virsh start ${PS_BM_NAME}
		PS_BM_NAME_IR=`echo ${PS_BM_NAME}|sed -e "s/_\|-//g"`
		sleep 3
		let "lastnum = i + 50"
		echo "  ${PS_BM_NAME_IR}:
    uuid: 00000000-0000-0000-0000-00000000000${i}
    driver_info:
      power:
        ssh_port: 22
        ssh_username: jenkins
        ssh_virt_type: virsh
        ssh_address: 192.168.10.1
        ssh_key_filename: /home/ironic/.ssh/id_rsa
    nics:
      -
        mac: ${PS_BM_MAC}
    driver: pxe_ssh_ansible
    ipv4_address: 192.168.10.${lastnum}
    name: ${PS_BM_NAME_IR}
" >> /tmp/baremetal.yml
            done
    else
        cp /tmp/biftost_playbooks/baremetal.yml /tmp/
fi    
cp -r /tmp/biftost_playbooks/custom_inventory ~jenkins/workspace/bifrost_remote/playbooks/
cd ~jenkins/workspace/bifrost_remote/playbooks/
sed -i "s/10.20.0/192.168.10/g" install-target.yaml
echo "[target]
${VM_IP} ansible_connection=ssh ansible_user=${VM_USER} ansible_ssh_pass=${VM_PASS} ansible_become_pass=${VM_USER}" > ./custom_inventory/target
ansible-playbook -vvvv -s -i custom_inventory/target install-target.yaml
export BIFROST_INVENTORY_SOURCE=/tmp/baremetal.yml
ansible-playbook -vvvv -i custom_inventory/ enroll-dynamic.yaml
ansible-playbook -vvvv -i custom_inventory/ deploy-dynamic.yaml
