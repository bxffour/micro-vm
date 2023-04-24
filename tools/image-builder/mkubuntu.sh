#!/bin/bash

set -e

ubuntu_image=ubuntu:20.04
container_name=ubuntu
rootfs_tmp_dir=/tmp/rootfs
ubuntu_drive=ubuntu.ext4
core_packages=("systemd" "systemd-sysv" "udev")
extra_packages=("iputils-ping" "sudo" "dnsutils" "socat" "vim" "iproute2" "net-tools" "util-linux")

cleanup() {
  set +e
  docker stop $container_name
  sudo umount $rootfs_tmp_dir
}

failfunc() {
  set +e
  echo "cleaning up build..."
  docker rm -f $container_name
  sudo umount $rootfs_tmp_dir
  rm $ubuntu_drive
} 

trap failfunc ERR SIGTERM SIGINT

function parse_args() {
  local image=""
  local packages=()
  local drive=""

  while getopts ':hi:p:o:' flag; do
    case $flag in
      i) validate_image $OPTARG; image=$OPTARG;;
      p) packages+=("$OPTARG");;
      o) drive=$OPTARG;;
      h) usage >&2;exit 0;;
      \?) echo "Invalid option: -$OPTARG" >&2; usage >&2; exit 1;;
      :) echo "Option -$OPTARG requires an argument." >&2; usage >&2; exit 1;;
    esac
  done

  if [ -n "$image" ]; then
    ubuntu_image=$image
  fi

  if [ -n "$drive" ]; then
    ubuntu_drive=$drive
  fi

  for package in "${packages[@]}"; do
    extra_packages+=$packages
  done
}

validate_image() {
  local image=$1
  # match base image that starts with ubuntu
  if [[ ! $image =~ ^([a-zA-Z0-9_\.-]+\/)?ubuntu(:.+)?$ ]]; then
    echo "Error: Image provided is not an Ubuntu image." >&2
    echo
    usage
    exit 1
  fi
}

# mkdrive: creates a new ext4 filesystem image
function mkdrive() {
  if [ -f $ubuntu_drive ]; then
    echo "error: drive $ubuntu_drive already exists"
    exit 1
  fi

  if [ ! -d $rootfs_tmp_dir ]; then
    mkdir $rootfs_tmp_dir
  fi
  
  dd if=/dev/zero of=$ubuntu_drive bs=1M count=500
  mkfs.ext4 -b 4096 $ubuntu_drive

  sudo mount $ubuntu_drive $rootfs_tmp_dir
}

# creates a the ext4 filesystem using the provided image as base
function docker-build() {
  set -x
  docker run --rm -d --name $container_name -v $rootfs_tmp_dir:/rootfs $ubuntu_image tail -f /dev/null
  docker exec -it $container_name bash -c 'echo "tzdata tzdata/Areas select ETC" | debconf-set-selections'
  docker exec -it $container_name bash -c 'echo "tzdata tzdata/Zones/ETC select UTC" | debconf-set-selections'
  docker exec -it $container_name bash -c "apt update"
  docker exec -it $container_name bash -c "DEBIAN_FRONTEND=noninteractive apt install -y ${core_packages[*]} ${extra_packages[*]}"
  docker exec -it $container_name bash -c 'echo "root:root" | chpasswd'
  docker exec -it $container_name bash -c 'hostnamectl'
  docker exec -it $container_name bash -c 'for d in bin etc lib lib32 lib64 libx32 root sbin usr var; do tar c "/$d" | tar x -C /rootfs; done'
  docker exec -it $container_name bash -c 'for dir in dev proc run sys; do mkdir /rootfs/${dir}; done'
  set +x
}

function usage() {
  echo "Usage: $0 [-h] [-i IMAGE] [-p PACKAGES] [-o OUTPUT]"
  echo "Options:"
  echo "  -h               Show this help message and exit."
  echo "  -i IMAGE"
  echo "                   The Docker image to use as the base for the build."
  echo "                   Defaults to \`$ubuntu_image\`."
  echo "  -p PACKAGES"
  echo "                   A list of packages to install on the image."
  echo "                   Defaults to \`${extra_packages[*]}\`."
  echo "  -o OUTPUT"
  echo "                   The path to the output file."
  echo "                   Defaults to \`$ubuntu_drive\`."
  echo ""
  echo "This script builds a custom Ubuntu image with the specified packages."
  echo "The image is stored in the specified output file."
}

main() {
  parse_args "$@"
  mkdrive
  docker-build
  cleanup
}

main "$@"