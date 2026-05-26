	.file	"getcallerpc-Linux-amd64.S"
	.text
	.type	getcallerpc,@function
	.global	getcallerpc
getcallerpc:
	movq	8(%rbp), %rax
	ret
