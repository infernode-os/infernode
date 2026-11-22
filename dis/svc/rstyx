#!/dis/sh.dis -n
load std
# Authentication alone does not protect the exported console and namespace;
# require both confidentiality and record integrity, as the bare-metal service does.
listen -a aes_256_gcm 'tcp!*!rstyx' {runas $user auxi/rstyxd&}
#and {ftest -d /net/il} {listen -a aes_256_gcm 'il!*!rstyx' {runas $user auxi/rstyxd&}}
