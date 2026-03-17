#!/bin/bash

# 检查是否为root用户
if [ `whoami` != "root" ];then
    echo "This script must be run as root!"
    exit 1
fi

# 安装必要软件（移除kpartx，保留核心依赖）
apt update
apt install -y dosfstools parted rsync util-linux  # util-linux包含losetup，系统一般自带

echo ""
echo "software is ready"

# 定义镜像文件名（支持自定义参数）
file="rpi-`date +%Y%m%d%H%M%S`.img"
if [ "x$1" != "x" ];then
    file="$1"
fi

# 获取boot分区挂载点
boot_mnt=`findmnt -n /dev/sda1 | awk '{print $1}'`

# 获取根分区信息
root_info=`df -PT / | tail -n 1`
root_type=`echo $root_info | awk '{print $2}'`

# 计算镜像大小（根分区+boot分区，预留20%空间）
dr=`echo $root_info | awk '{print $4}'`
db=`df -P | grep /dev/sda1 | awk '{print $2}'`
ds=`echo $dr $db |awk '{print int(($1+$2)*1.2)}'`

echo "create $file ..."

# 创建空镜像文件
dd if=/dev/zero of=$file bs=1K count=0 seek=$ds

# 获取原磁盘分区的起始/结束扇区
start=`fdisk -l /dev/sda| awk 'NR==10 {print $2}'`
end=`fdisk -l /dev/sda| awk 'NR==10 {print $3}'`

# 处理带*的启动分区扇区
if [ "$start" == "*" ];then
    start=`fdisk -l /dev/sda| awk 'NR==10 {print $3}'`
    end=`fdisk -l /dev/sda| awk 'NR==10 {print $4}'`
fi

start=`echo $start's'`
end=`echo $end's'`
end2=`fdisk -l /dev/sda| awk 'NR==11 {print $2}'`
end2=`echo $end2's'`

echo "start=$start"
echo "end=$end"
echo "end2=$end2"

# 分区镜像文件
parted $file --script -- mklabel msdos
parted $file --script -- mkpart primary fat32 $start $end
parted $file --script -- mkpart primary ext4 $end2 -1

# ========== 替换kpartx的核心部分 ==========
# 1. 创建循环设备并自动扫描分区（替代kpartx -va）
loopdevice=`losetup -f --show -P $file`  # -P 参数自动扫描分区
echo "loopdevice=$loopdevice"

# 2. 直接使用循环设备的分区文件（无需mapper）
partBoot="${loopdevice}p1"  # 如 /dev/loop0p1
partRoot="${loopdevice}p2"  # 如 /dev/loop0p2
# ========== 替换结束 ==========

echo "partBoot=$partBoot"
echo "partRoot=$partRoot"

# 等待分区设备文件创建完成
sleep 5s

# 获取原分区和新分区的PARTUUID
opartuuidb=`blkid -o export /dev/sda1 | grep PARTUUID`
opartuuidr=`blkid -o export /dev/sda2 | grep PARTUUID`
npartuuidb=`blkid -o export ${partBoot} | grep PARTUUID`
npartuuidr=`blkid -o export ${partRoot} | grep PARTUUID`

# 获取分区标签
boot_label=`dosfslabel /dev/sda1 | tail -n 1`
root_label=`e2label /dev/sda2 | tail -n 1`

# 格式化新分区
mkfs.vfat -F 32 -n "$boot_label" $partBoot
echo "$partBoot format success"

mkfs.ext4 $partRoot
e2label $partRoot $root_label
echo "$partRoot format success"

# 复制boot分区内容
mount -t vfat $partBoot /mnt
cp -rfp ${boot_mnt}/* /mnt/
sed -i "s/$opartuuidr/$npartuuidr/g" /mnt/cmdline.txt
sync
umount /mnt

# 复制根分区内容
mount -t ext4 $partRoot /mnt

# 处理swap文件排除
if [ -f /etc/dphys-swapfile ]; then
    SWAPFILE=`cat /etc/dphys-swapfile | grep ^CONF_SWAPFILE | cut -f 2 -d=`
    if [ "$SWAPFILE" = "" ]; then
        SWAPFILE=/var/swap
    fi
    EXCLUDE_SWAPFILE="--exclude $SWAPFILE"
fi

# 同步根文件系统
cd /mnt
rsync --force -rltWDEgop --delete --stats --progress \
    $EXCLUDE_SWAPFILE \
    --exclude ".gvfs" \
    --exclude "$boot_mnt" \
    --exclude "/dev" \
    --exclude "/media" \
    --exclude "/mnt" \
    --exclude "/proc" \
    --exclude "/run" \
    --exclude "/snap" \
    --exclude "/sys" \
    --exclude "/tmp" \
    --exclude "lost\+found" \
    --exclude "$file" \
    / ./

# 创建必要的目录
if [ ! -d $boot_mnt ]; then
    mkdir $boot_mnt
fi
if [ -d /snap ]; then
    mkdir /mnt/snap
fi
for i in boot dev media mnt proc run sys tmp; do  # 修复原脚本重复的boot
    if [ ! -d /mnt/$i ]; then
        mkdir /mnt/$i
    fi
done
chmod a+w /mnt/tmp  # 确保tmp目录可写

# 更新fstab中的PARTUUID
cd
sed -i "s/$opartuuidb/$npartuuidb/g" /mnt/etc/fstab
sed -i "s/$opartuuidr/$npartuuidr/g" /mnt/etc/fstab

sync

# 卸载分区
umount /mnt

# ========== 替换kpartx清理逻辑 ==========
# 直接删除循环设备（替代kpartx -d + losetup -d）
losetup -d $loopdevice
# ========== 替换结束 ==========

echo "镜像创建完成：$file"
