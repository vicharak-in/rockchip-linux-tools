#!/bin/bash

# Variables
RAWIMG=raw.img
LOADER1_START=64
PARAMETER=$(grep <package-file -wi parameter | awk '{printf $2}' | sed 's/\r//g')
PARTITIONS=()
PARTITION_INDEX=0

# Function to align the size
ALIGN() {
	X=$1
	A=$2
	OUT=$(($((X + A - 1)) & $((~$((A - 1))))))
	printf 0x%x ${OUT}
}

echo "Generating raw image : ${RAWIMG} !"

rm -rf ${RAWIMG}

ROOTFS_LAST=$(grep "rootfs:grow" Image/parameter.txt)
if [ -z "${ROOTFS_LAST}" ]; then
	echo "Resize rootfs partition size"
	FILE_P=$(readlink -f Image/rootfs.img)
	FS_INFO=$(dumpe2fs -h "${FILE_P}")
	BLOCK_COUNT=$(echo "${FS_INFO}" | grep "^Block count" | cut -d ":" -f 2 | tr -d "[:blank:]")
	INODE_COUNT=$(echo "${FS_INFO}" | grep "^Inode count" | cut -d ":" -f 2 | tr -d "[:blank:]")
	BLOCK_SIZE=$(echo "${FS_INFO}" | grep "^Block size" | cut -d ":" -f 2 | tr -d "[:blank:]")
	INODE_SIZE=$(echo "${FS_INFO}" | grep "^Inode size" | cut -d ":" -f 2 | tr -d "[:blank:]")
	BLOCK_SIZE_IN_S=$((BLOCK_SIZE >> 9))
	INODE_SIZE_IN_S=$((INODE_SIZE >> 9))
	SKIP_BLOCK=70
	EXTRA_SIZE=$((50 * 1024 * 2)) #50M

	FSIZE=$((BLOCK_COUNT * BLOCK_SIZE_IN_S + INODE_COUNT * INODE_SIZE_IN_S + EXTRA_SIZE + SKIP_BLOCK))
	PSIZE=$(ALIGN $((FSIZE)) 512)
	PARA_FILE=$(readlink -f Image/parameter.txt)

	ORIGIN=$(grep -Eo "0x[0-9a-fA-F]*@0x[0-9a-fA-F]*\(rootfs" "${PARA_FILE}")
	#NEWSTR=$(echo "${ORIGIN}" | sed "s/.*@/${PSIZE}@/g")
	NEWSTR=${ORIGIN//.*@/${PSIZE}@}
	OFFSET=$(echo "${NEWSTR}" | grep -Eo "@0x[0-9a-fA-F]*" | cut -f 2 -d "@")
	NEXT_START=$(printf 0x%x $((PSIZE + OFFSET)))
	sed -i.orig "s/$ORIGIN/$NEWSTR/g" "$PARA_FILE"
	sed -i "/^CMDLINE.*/s/-@0x[0-9a-fA-F]*/-@$NEXT_START/g" "$PARA_FILE"
fi

for PARTITION in $(grep <"${PARAMETER}" '^CMDLINE' | sed 's/ //g' | sed 's/.*:\(0x.*[^)])\).*/\1/' | sed 's/,/ /g'); do
	PARTITION_NAME=$(echo "${PARTITION}" | sed 's/\(.*\)(\(.*\))/\2/' | awk -F : {'print $1'})
	PARTITION_FLAG=$(echo "${PARTITION}" | sed 's/\(.*\)(\(.*\))/\2/' | awk -F : {'print $2'})
	PARTITION_START=$(echo "${PARTITION}" | sed 's/.*@\(.*\)(.*)/\1/')
	PARTITION_LENGTH=$(echo "${PARTITION}" | sed 's/\(.*\)@.*/\1/')

	PARTITIONS+=("$PARTITION_NAME")
	PARTITION_INDEX=$((PARTITION_INDEX + 1))

	eval "${PARTITION_NAME}_START_PARTITION=${PARTITION_START}"
	eval "${PARTITION_NAME}_FLAG_PARTITION=${PARTITION_FLAG}"
	eval "${PARTITION_NAME}_LENGTH_PARTITION=${PARTITION_LENGTH}"
	eval "${PARTITION_NAME}_INDEX_PARTITION=${PARTITION_INDEX}"
done

LAST_PARTITION_IMG=$(grep <package-file -wi "${PARTITION_NAME}" | awk '{printf $2}' | sed 's/\r//g')

if [[ -f ${LAST_PARTITION_IMG} ]]; then
	IMG_ROOTFS_SIZE=$(stat -L --format="%s" "${LAST_PARTITION_IMG}")
else
	IMG_ROOTFS_SIZE=0
fi

# Calculate the size of the GPT image
# 0x2000 is the size of the GPT header
# 512 is the size of the sector
# 2 is the size of the GPT backup header
# 1M is the size of the MBR
GPTIMG_MIN_SIZE=$((IMG_ROOTFS_SIZE + $((PARTITION_START + 0x2000)) * 512))
GPT_IMAGE_SIZE=$((GPTIMG_MIN_SIZE / 1024 / 1024 + 2))

# Create the raw image with the size of the GPT image
dd if=/dev/zero of=${RAWIMG} bs=1M count=0 seek="${GPT_IMAGE_SIZE}"
parted -s ${RAWIMG} mklabel gpt

# Loop through the partitions and create them
for PARTITION in "${PARTITIONS[@]}"; do
	PSTART=${PARTITION}_START_PARTITION
	PFLAG=${PARTITION}_FLAG_PARTITION
	PLENGTH=${PARTITION}_LENGTH_PARTITION
	PINDEX=${PARTITION}_INDEX_PARTITION
	PSTART=${!PSTART}
	PFLAG=${!PFLAG}
	PLENGTH=${!PLENGTH}
	PINDEX=${!PINDEX}

	# Increase the partition size if required
	if [ "${PLENGTH}" == "-" ]; then
		echo "EXPAND"
		parted -s ${RAWIMG} -- unit s mkpart "${PARTITION}" $(((PSTART + 0x00))) -34s
	else
		PEND=$(((PSTART + 0x00 + PLENGTH)))
		parted -s ${RAWIMG} unit s mkpart "${PARTITION}" $(((PSTART + 0x00))) $((PEND - 1))
	fi

	# Enable legacy_boot flag for bootable partition
	if [ "${PFLAG}"x == "bootable"x ]; then
		parted -s ${RAWIMG} set "${PINDEX}" legacy_boot on
	fi
done

UUID=$(grep <"${PARAMETER}" 'uuid' | cut -f 2 -d "=")
VOL=$(grep <"${PARAMETER}" 'uuid' | cut -f 1 -d "=" | cut -f 2 -d ":")
VOLINDEX=${VOL}_INDEX_PARTITION
VOLINDEX=${!VOLINDEX}

# Apply changes to the GPT image using gdisk
gdisk ${RAWIMG} <<EOF
x
c
${VOLINDEX}
${UUID}
w
y
EOF

# Copy the bootloader to the raw image
if [ "$RK_IDBLOCK_UPDATE" == "true" ]; then
	if ! dd if="Image/idblock.bin" of="${RAWIMG}" seek="${LOADER1_START}" conv=notrunc; then
		echo -e "\e[31m error: failed to update idblock.bin \e[0m"
		exit 1
	fi
else
	if ! dd if="Image/idbloader.img" of="${RAWIMG}" seek="${LOADER1_START}" conv=notrunc; then
		echo -e "\e[31m error: failed to update idbloader.img \e[0m"
		exit 1
	fi
fi

# Copy the partition images to the raw image
for PARTITION in "${PARTITIONS[@]}"; do
	PSTART=${PARTITION}_START_PARTITION
	PSTART=${!PSTART}

	IMGFILE=$(grep <package-file -wi "${PARTITION}" | awk '{printf $2}' | sed 's/\r//g')

	if [[ x"$IMGFILE" != x ]]; then
		if [[ -f "$IMGFILE" ]]; then
			echo "${PARTITION}" "${IMGFILE}" "${PSTART}"
			if ! dd if="${IMGFILE}" of="${RAWIMG}" seek=$(((PSTART + 0x00))) conv=notrunc,fsync; then
				echo -e "\e[31m error: failed to update ${PARTITION} \e[0m"
				exit 1
			fi
		else
			if [[ x"$IMGFILE" != xRESERVED ]]; then
				echo -e "\e[31m error: $IMGFILE not found! \e[0m"
				exit 1
			fi
		fi
	fi
done

# Restore the original parameter file
if [ -e "${PARA_FILE}".orig ]; then
	mv "${PARA_FILE}".orig "${PARA_FILE}"
	exit $?
else
	exit 0
fi

echo "Build raw img completed"
