#!/bin/bash
########################################
#########                      #########
#########   BOOTLOADER HIKEY960 ########
#########                      #########
########################################




########################################
#########                      #########
#########   Compilation        #########
#########                      #########
########################################
p_b=`pwd`/build
parts=`pwd`/parts
mkdir $p_b
mkdir $parts
###### DOWNLOAD GCC-LINARO
echo "Prepare toolchain" 
if [ -f "gcc-linaro.tar.xz" ]
then
    echo "GCC already downloaded"
else
    wget -O gcc-linaro.tar.xz "http://releases.linaro.org/components/toolchain/binaries/5.5-2017.10/aarch64-linux-gnu/gcc-linaro-5.5.0-2017.10-x86_64_aarch64-linux-gnu.tar.xz" 
    tar xvf gcc-linaro.tar.xz
fi
cd $parts
echo "Partitions part"
if [ -e "boot.img" ]
then
    echo "Boot partition already downloaded"
else
    echo "Download boot partition"
    wget -O boot.img.gz http://snapshots.linaro.org/96boards/hikey/linaro/debian/latest/boot-linaro-stretch-developer-hikey-20190720-33.img.gz
    echo "Gunzip boot" 
    gunzip -d boot.img.gz
fi

if [ -e "root.img" ]
then
    echo "Rootfs already downloaded"
else
    echo "Download rootfs"
    wget -O rootfs.sparse.img.gz http://snapshots.linaro.org/96boards/hikey/linaro/debian/latest/rootfs-linaro-stretch-developer-hikey-20190720-33.img.gz
    echo "Gunzip"
    gunzip -d rootfs.sparse.img.gz
    echo "Convert rootfs from simg to img"
    simg2img rootfs.sparse.img rootfs.img
    rm rootfs.sparse.img
fi

if [ -e "patch.tar.xz" ]
    echo "Patch already downloaded"
    cd patch
    cp boot/devicetree-Image-hi3660-hikey960.dtb $p_b/
    cd ..
else
    echo "Download patch"
    wget http://snapshots.linaro.org/reference-platform/embedded/morty/hikey960/129/rpb/rpb-console-image-hikey960-20180209072216-129.rootfs.tar.xz
    mkdir patch
    echo "Extracting patch data"
    tar axf rpb-console-image-hikey960-20180209072216-129.rootfs.tar.xz -C patch
    cd patch
    echo "Creating patch.tar"
    tar Jcvf patch.tar.xz boot/*.dtb boot/Image* lib/modules/4.14.0-rc7-linaro-hikey960/
    mv patch.tar.xz ../
    cd ..
fi

mkdir $b/loop
echo "Applying patch"
sudo mount -o loop rootfs.img loop/
cd loop
sudo tar axf ../patch.tar.xz
cd ..
sudo umount loop
cd ..
##############################
#### Compile new kernel  #####
#############################
mkdir $p_b
### TOOLCHAIN
echo 'Compile kernel'
export PATH=$PATH:`pwd`/gcc-linaro-5.5.0-2017.10-x86_64_aarch64-linux-gnu/bin
export BUILD_PATH=$p_b
if [ -e linux ]
then
    echo 'Linux kernel already downloaded'
else
    git clone https://github.com/96boards-hikey/linux.git
fi
cd linux
git checkout working-hikey960-v4.14-rc7-2017-11-03
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
make defconfig
make -j8
## DA TESTARE 
make modules
make INSTALL_MOD_PATH=$p_b modules install
cp -f arch/$ARCH/boot/Image $p_b/Image
cp -f arch/$ARCH/boot/dts/hisilicon/hi3660-hikey960.dtb $p_b/Image.dtb

#### Compile XEN
echo "Compile XEN"
export PATH=$PATH:`pwd`/gcc-linaro-5.5.0-2017.10-x86_64_aarch64-linux-gnu/bin
export BUILD_PATH=$p_b
if [ -e 'xen' ]
then
    echo 'XEN already downloaded'
else
    git clone git://xenbits.xen.org/xen.git
fi
cd xen
git checkout tags/RELEASE-4.12.0
cd xen
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
export XEN_TARGET_ARCH=arm64
make defconfig
make -j8
cp xen.efi $p_b/xen.efi

### GRUB
echo 'Compiling GRUB'
export PATH=$PATH:`pwd`/gcc-linaro-5.5.0-2017.10-x86_64_aarch64-linux-gnu/bin
export BUILD_PATH=$p_b
#### Only for UBUNTU
##sudo apt install automake autoconf autopoint bison flex
if [ -e grub ]
then
    echo 'GRUB already downloaded'
else
    git clone https://git.savannah.gnu.org/git/grub.git
fi
cd grub
#### Cross compilation
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
echo 'Bootstrap'
./bootstrap
echo 'Configure'
./configure --prefix=/usr --target=aarch64-linux-gnu --with-platform=efi
echo 'Make'
make
mkdir $p_b/grub-install
make DESTDIR=$p_b/grub-install install
### Configuration
cat > $p_b/grub.config << EOF
set root=(hd4,1)
set prefix=(\$root)/boot
configfile \$prefix/grub.cfg
EOF
$p_b/grub-install/usr/bin/grub-mkimage \
               --config $p_b/grub.config \
               --dtb $p_b/devicetree-Image-hi3660-hikey960.dtb \
               --directory=$p_b/grub-install/usr/lib/grub/arm64-efi \
               --output=$p_b/grubaa64.efi \
               --format=arm64-efi \
               --prefix="/boot/grub" \
               boot chain configfile echo efinet eval ext2 fat font gettext gfxterm gzio help linux loadenv lsefi normal part_gpt part_msdos read regexp search search_fs_file search_fs_uuid search_label terminal terminfo test tftp time xen_boot



#### Create rootfs
echo "Create rootfs"
cd $parts
sudo mount -o loop rootfs.img loop/
sudo cp $p_b/xen.efi ./loop/boot/xen.efi
cat << EOF | sudo tee ./loop/boot/grub.cfg
set default="0"
set timeout=60

menuentry 'XEN Hypervisor' {
    xen_hypervisor /boot/xen.efi guest_loglvl=all loglvl=all console=dtuart dtuart=/soc/serial@fff32000 efi=no-rs hmp-unsafe=true
    xen_module /boot/Image console=tty0 console=hvc0 root=/dev/mmcblk0p1 rw efi=noruntime
    devicetree /boot/devicetree-Image-hi3660-hikey960.dtb
}
menuentry 'CE Reference Platform (HiKey960 rpb)' {
    linux /boot/Image console=tty0 console=ttyAMA6,115200n8 root=/dev/mmcblk0p1 rootwait rw efi=noruntime
        devicetree /boot/devicetree-Image-hi3660-hikey960.dtb
}
EOF
sudo umount loop
sudo mount -o loop boot.img loop/
sudo cp $p_b/grubaa64.efi loop/EFI/BOOT/GRUBAA64.efi
sudo umount loop
read -p 'Rootfs in sdcard?'
echo 'create partition on sdcard'#
mkdir sdcard
sudo mount /dev/sda1 ./sdcard/
sudo mount -o loop rootfs.img loop
echo 'Copying files...'
sudo cp -r loop/* sdcard/
sudo umount sdcard
sudo umount loop

img2simg boot.img boot.sparse.img 4096
##
### Flash various partition
echo 'sudo fastboot flash boot boot.sparse.img'
read -p 'Fastboot? ' ans
sudo fastboot flash boot boot.sparse.img
