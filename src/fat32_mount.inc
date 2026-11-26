%define FAT_MOUNT_COUNT 4
%define FAT_MOUNT_NAME_SIZE 32

struc fat_volume
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
    .name:                resb FAT_MOUNT_NAME_SIZE
    alignb 8
endstruc
