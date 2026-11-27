struc vpci
    .feature_select: resd 1
    .features: resd 1
    .driver_select: resd 1
    .driver_features: resd 1
    .msix: resw 1
    .num_queues: resw 1
    .status: resb 1
    .generation: resb 1
    .queue_select: resw 1
    .queue_size: resw 1
    .queue_msix: resw 1
    .queue_enable: resw 1
    .queue_notify: resw 1
    .desc: resq 1
    .avail: resq 1
    .used: resq 1
endstruc
