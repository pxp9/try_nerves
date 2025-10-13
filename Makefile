qemu:
	qemu-system-x86_64 -drive file=disk.img,if=virtio,format=raw -net nic,model=virtio -net user,hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:80 -nographic -serial mon:stdio -m 1024
