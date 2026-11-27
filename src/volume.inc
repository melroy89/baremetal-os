; Shared mount identity and backend geometry.
%define VOLUME_MOUNT_COUNT 4
%define VOLUME_MOUNT_NAME_SIZE 32
%define FS_FAT32 0
%define FS_EXT2 1

struc mount_volume
    .volume_base:          resq 1
    .partition_last:       resq 1
    .total_sectors:        resq 1
    .data_start:           resq 1
    .device:               resd 1
    .reserved_sectors:    resd 1
    .fat_copies:          resd 1
    .sectors_per_fat:     resd 1
    .sectors_per_cluster: resd 1
    .last_cluster:        resd 1
    .root_cluster:        resd 1
    .fsinfo_lba:          resd 1
    .backup_fsinfo_lba:   resd 1
    .mounted:             resb 1
    .pending_write:       resb 1
    .write_error:         resb 1
    .name:                resb VOLUME_MOUNT_NAME_SIZE
    .type:                resb 1
    .read_only:           resb 1
    alignb 4
    .ext_blocks:          resd 1
    .ext_inodes:          resd 1
    .ext_blocks_group:    resd 1
    .ext_inodes_group:    resd 1
    .ext_inode_size:      resd 1
    .ext_inode_blocks:    resd 1
    .ext_gdt_blocks:      resd 1
    .ext_features:        resd 1
    .ext_groups:          resd 1
    .ext_first_inode:     resd 1
    alignb 8
endstruc
