#!/bin/sh

#
# make-multiver-instimg img1 img2 ... imgN
#    imgn = NetBSD UEFI install/live image
# eg.
# make-multiver-instimg  /foo/netbsdsrc/current/release/images/NetBSD-9.99.17-amd64-uefi-install.img.gz \
#                       /foo/netbsdsrc/8.1/release/images/NetBSD-8.1_STABLE-amd64-uefi-install.img.gz
#

: ${TMPDIR:=/tmp}
: ${GPT:=gpt}
: ${SUDO:=sudo}
: ${VND:=/dev/vnd0d}

args=$(getopt do: "$@")
if [ $? -ne 0 ]; then
    echo >&2 "Usage: $0 [-d] [-o output] image1 image2 ...";
    exit 2
fi
set -- $args
while [ $# -ne 0 ]; do
    case $1 in
	-d) OptDebug=yes;;
	-o) Output=$2; shift;;
	--) shift; break;;
    esac
    shift
done

: ${OptDebug:=no}
: ${Output:=netbsd-multiver.img}

if [ $OptDebug = yes ]; then
    DBG=
    TmpDir=./Work$$
else
    DBG=:
    TmpDir=$TMPDIR/multiverinst$$
    trap "rm -rf '$TmpDir'" 0 1 2 3 15
fi
mkdir -p "$TmpDir/mnt"


#XXX
if ! type "$GPT"; then
    GPT=/u1/w/nb/tnf-current/tools/bin/nbgpt
fi

case $(basename "$GPT") in
    gpt)
	gptcmd () {
	    local dev
	    dev=$1; shift
	    "$GPT" "$@" $dev
	};;
    *)
	gptcmd () {
	    "$GPT" "$@"
	};;
esac


case $(uname -s) in
NetBSD)
    # mount_image_file fstype image_file mount_point
    mount_image_file () {
	$SUDO /usr/sbin/vndconfig -c $VND $2
	$SUDO mount -t $1 $VND $3
    }
    umount_image_file () {
	$SUDO umount $1
	$SUDO /usr/sbin/vndconfig -u $VND
    }
    ;;
Linux)
    mount_image_file () {
	$SUDO mount -t $1 -o loop $2 $3
    }
    umount_image_file () {
	$SUDO umount $1
    }
    ;;
*)
    echo >&2 "$(uname -s): not supported"
    ;;
esac


fullpath () {
    case "$1" in
	/*) echo "$1";;
	*) echo "$(/bin/pwd)/$1";;
    esac
}

#
# run dd with bigger buffer size for speed
# Usage: run_dd input output count skip seek
#
run_dd () {
    local bs _bs input output count skip seek
    input=$1; shift
    output=$1; shift
    count=$1; shift
    if [ $# -gt 0 ]; then skip=$1; shift; fi
    if [ $# -gt 0 ]; then seek=$1; shift; fi
    $DBG echo 'run_dd(1)' $input,$output,$count,$skip,$seek,$*

    for bs in $((1024 * 1024 * 8)) $((1024 * 1024)) $((512 * 1024)) 512
    do
	_bs=$((bs / 512))
	if [ $((count % _bs + skip % _bs + seek % _bs)) = 0 ]; then
	    break
	fi
    done

    count=$((count * 512 / bs))
    skip=$((skip * 512 / bs))
    seek=$((seek * 512 / bs))

    $DBG echo 'run_dd(2)' $input,$output,$count,$skip,$seek,$*

    set -- "$@" if="$input" of="$output"
    if [ $count -gt 0 ]; then
	set -- "$@" count=$count
    fi
    if [ $skip -gt 0 ]; then
	set -- "$@" skip=$skip
    fi
    if [ $seek -gt 0 ]; then
	set -- "$@" seek=$seek
    fi

    dd bs=$bs "$@"
}


cat - <<'EOF' > $TmpDir/readgpt.awk
NR==1 { next }
{
    start = $1
    size = $2
    if ($3 ~ /^[0-9]+$/) {
        idx = $3
        $3 = ""
    }
    else {
       idx = ""
    }
    $1 = ""
    $2 = ""

    sub(/^ */, "")

    # print start " " size " | " idx " | " $0

    if ($0 ~ /^GPT part - EFI/ ) {
	EFIstart = start
	EFIsize = size
    }
    if ($0 ~ /^GPT part - NetBSD/) {
	NBstart = start
	NBsize = size
	exit
    }
    if ($0 ~ /MBR part 169/) {
	# no GPT. legacy MBR partitioned image.
	NBstart = start
	NBsize = size
	EFIstart = 0
	EFIsize = 0
    }
}
END {
    print NBstart, NBsize, EFIstart, EFIsize
}
EOF

#
# uncompress_and_read index imagefile
#
# output: uncompressed start size
#
uncompress_and_read () {
    local f
    f="$TmpDir/$1.srcimg"
    case "$2" in
	*.gz) gunzip -c $2 > $f;;
	*.xz) xz --decompress --stdout $2 > $f;;
	/*) ln -sf $2 $f;;
	*) ln -sf $(/bin/pwd)/$2 $f;;
    esac
    echo $f $(gptcmd $f show | awk -f $TmpDir/readgpt.awk)
}


n=0
for img
do
    n=$((n+1))
    shift
    set -- $(uncompress_and_read $n $img) ":" "$@"
    uc=$1; shift
    nst=$1; shift
    nsz=$1; shift
    est=$1; shift
    esz=$1; shift

    if [ "$1" = ":" ]; then
	shift
    else
	echo >&2 "missing some partitions in $img"
	exit 1
    fi

    $DBG echo $img $uc, $nst $nsz $est $esz

    if [ $n = 1 ]; then
	EFIstart=$est
	EFIsize=$esz

	# copy GPT header, GPT table and EFI partition
	#dd if=$uc of="$Output" count=$nst
	run_dd $uc "$Output" $nst
	NBstart=$nst
	NBstart1=$nst
	sz=$((nst + nsz))
    else
	eval "NBstart$n=$sz"
	sz=$((sz + nsz))
    fi

    eval "NBsize$n=$nsz"
    # dd if=$uc of=$TmpDir/$n.img skip=$nst count=$nsz
    run_dd $uc $TmpDir/$n.img $nsz $nst
done

$DBG echo 'EFI: ' $EFIstart, $EFIsize

#modify boot.cfg

dd if=/dev/zero count=$((1024 * 1024 / 512)) of="$Output" seek=$sz
# re-create GPT table to add the secondary table and header.
gptcmd "$Output" destroy
gptcmd "$Output" create
gptcmd "$Output" add -b $EFIstart -s $EFIsize -t efi -l "EFI system"

# for each NetBSD partition:
i=1
while [ $i -le $n ]; do
    eval "gptcmd "$Output" add -b \$NBstart$i -s \$NBsize$i -t ffs"
    guid=$(gptcmd "$Output" show -i$((i+1)) | awk '/^GUID:/ {print $2}')
    eval "guid$i=$guid"
    i=$((i+1))
done

# for each NetBSD partition, the first one at the last
for i in $(seq 2 $n) 1; do
    mount_image_file ffs $TmpDir/$i.img $TmpDir/mnt
    $DBG ls $TmpDir/mnt
    
    #   modify /etc/fstab
    eval "guid=\$guid$i"
    sed -e 's/^NAME=[-0-9a-f]*/NAME='"$guid/" -e 's/^ROOT.a/NAME='"$guid/" < $TmpDir/mnt/etc/fstab > $TmpDir/fstab.NEW
    $SUDO mv $TmpDir/fstab.NEW $TmpDir/mnt/etc/fstab
    $DBG cat $TmpDir/mnt/etc/fstab

    if [ $i = 1 ]; then
	#  modify boot.cfg
	awk -v menu="$TmpDir/menu.txt" '
	#banner=Welcome to the NetBSD/amd64 9.99.17 installation image
	/^banner=Welcome to the NetBSD/ {
		osname=$4 " " $5;
		$5 = "(multiple versions)"}
	/menu=Install NetBSD/ {sub(/Install NetBSD/, "Install " osname); }
	/menu=Drop to/ {while ((getline line < menu) > 0) print line }
	{ print $0 }' $TmpDir/mnt/boot.cfg > $TmpDir/boot.cfg.NEW

	$SUDO cp $TmpDir/boot.cfg.NEW $TmpDir/mnt/boot.cfg
    else
	# get menus from boot.cfg and modify
	awk -v menu="$TmpDir/menu.txt" -v partition=$((i + 1)) '
	#banner=Welcome to the NetBSD/amd64 9.99.17 installation image
	/^banner=Welcome to/ {
		osname=$4 " " $5;
		device="hd0" substr("abcdefghijklmnopqrstuvwxyz", partition, 1) }
	/menu=Install NetBSD/ {
		sub(/Install NetBSD/, "Install " osname);
		sub(/:boot netbsd/, ":boot " device ":netbsd");
		print $0 >> menu }' $TmpDir/mnt/boot.cfg
    fi
    

    umount_image_file $TmpDir/mnt

    $DBG eval "echo \$NBstart$i \$NBsize$i"

    eval "st=\$NBstart$i"
    #dd if=$TmpDir/$i.img of="$Output" seek=$st conv=notrunc
    run_dd $TmpDir/$i.img "$Output" 0 0 $st conv=notrunc
done
    
# copy MBR
dd if=$TmpDir/1.srcimg of=$TmpDir/mbr bs=440 count=1

gptcmd "$Output" biosboot -i 2 -c $(fullpath "$TmpDir/mbr")
gptcmd "$Output" set -a bootme -i 2

$DBG gptcmd "$Output" show
