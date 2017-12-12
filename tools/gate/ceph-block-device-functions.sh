#!/bin/bash

function iscsi_loopback_create {
  # create a new, local, file-backed iSCSI device and connect
  # to it.  Prints the SCSI address of the initiator-side
  # device.
  LOOPBACK_NAME=$1
  LOOPBACK_SIZE=$2

  LOOPBACK_DIR=${LOOPBACK_DIR:-/tmp}
  
  # targetcli is spammy on stdout.  send its output to stderr.
  {
    LOOPBACK_DEV=`sudo targetcli ls /iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/luns/ 2>/dev/null|grep 'lun[0-9]'|wc -l`
    BACKSTORE=`mktemp -p ${LOOPBACK_DIR} ${LOOPBACK_NAME}.${LOOPBACK_DEV}.XXXXXXXXXX`

    if [ "x$HOST_OS" == "xubuntu" ]; then
      sudo targetcli backstores/fileio create ${BACKSTORE} ${LOOPBACK_DIR}/fileio-${BACKSTORE} ${LOOPBACK_SIZE}
    else
      sudo targetcli backstores/fileio create ${BACKSTORE} ${LOOPBACK_DIR}/fileio-${BACKSTORE} ${LOOPBACK_SIZE} write_back=false
    fi

    # we'll do these repeatedly, but they're idempotent and fairly cheap.
    sudo targetcli iscsi/ create iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/portals create 127.0.0.1 3260
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/acls/ create `sudo cat /etc/iscsi/initiatorname.iscsi | awk -F '=' '/^InitiatorName/ { print $NF}'`
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1 set attribute authentication=0

    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/luns/ create /backstores/fileio/${BACKSTORE}
    sudo iscsiadm -m discovery -t sendtargets -p 127.0.0.1 3260
    sudo iscsiadm -m node -T iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME} -p 127.0.0.1:3260 -l
    sudo iscsiadm -m node -T iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME} -R

    # it takes a moment for udev to get around to creating the block device.
    sudo udevadm settle
    BLOCKDEV=`readlink -f /dev/disk/by-path/ip-127.0.0.1:3260-iscsi-iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}-lun-${LOOPBACK_DEV}`
    sudo parted -s ${BLOCKDEV} mklabel gpt
    BLOCKNAM=`basename ${BLOCKDEV}`
    # seems like we need to wait for udev again after writing the disklabel.
    sudo udevadm settle
    SCSIDEV=`readlink -f /sys/block/${BLOCKNAM}/device`
  } 1>&2
  # existing code expects scsi devices in the form bus:x.y.x, but
  # we have bus:x:y:z.  Fix that up.
  basename ${SCSIDEV}|awk -F: '{print $1":"$2"."$3"."$4}'
  [ -b ${BLOCKDEV} ]
}

function ceph_devicepair_create {
  # create one or more {OSD, journal} device pairs.
  # takes OSD size, journal size, and number to create,
  # ie: ceph_devicepair_create 100G 5G 3
  # produces output like this:
  #
  # {
  #  "hostname": "host1",
  #  "block_devices": [
  #   {
  #    "device": "scsi@7:0.0.0",
  #    "journal": {
  #      "device": "scsi@8:0.0.0"
  #    },
  #    "name": "scsi-7-0-0-0-j-8-0-0-0",
  #    "type": "device"
  #   },
  #   [...]
  #  ]
  # }
  OSD_SIZE=$1
  JOURNAL_SIZE=$2
  N_OSDS=${3:-1}

  (
    while [ $N_OSDS -gt 0 ]; do
      OSD_DEV=`iscsi_loopback_create cephosd ${OSD_SIZE}`
      JOURNAL_DEV=`iscsi_loopback_create cephjournal ${JOURNAL_SIZE}`
       echo '[{"device": "scsi@'${OSD_DEV}'",'\
               '"journal": {"device": "scsi@'${JOURNAL_DEV}'"},'\
               '"name": "scsi-'`echo ${OSD_DEV}|tr ":." "-"`'-j-'`echo ${JOURNAL_DEV}|tr ":." "-"`'",'\
               '"type": "device"}]'
       N_OSDS=`expr $N_OSDS - 1`
    done
  )|jq --arg hostname `hostname` -s 'add|{"hostname": ($hostname), "block_devices": [.[]]}'
}

function ceph_merge_device_values {
  # given a possibly-overlapping set of json block device lists
  # as created by ceph_loopback_devicepair_create, produce a list
  # uniqified by name.
  jq  -s '{"block_devices": [.[]["block_devices"]]|add|unique_by(.name)}' $*
}

function ceph_label_device_hosts {
  # given a block device list as created by ceph_loopback_devicepair_create,
  # label its host for the OSDs it supports.
  jq -r '.block_devices[].hostname=.hostname|.block_devices|.[]| .hostname +" cephosd-device-"+.name +"=enabled"' $* |\
   xargs -l kubectl label nodes
}

sc=$0
fn=$1
shift;

case ${fn} in
  "ceph_label_device_hosts")
    ceph_label_device_hosts $*
    ;;
  "ceph_merge_device_values")
    ceph_merge_device_values $*
    ;;
 "ceph_device_pair_create")
    ceph_devicepair_create $*
    ;;
 *)
    echo "usage: ${sc} [devicepair_create|merge_device_values|label_device_hosts]"
    ;;
esac
