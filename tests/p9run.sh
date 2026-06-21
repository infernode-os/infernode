#!/dis/sh.dis
# Wrapper for tests/p9drive.dis: set up networking, mount a remote
# InferNode llmsrv (serve-llm) over 9P, then run the scenario suite.
# Args: $1=model  $2=remote(tcp!host!port)  $3=nruns  $4=scenarios.json
load std
model=$1
remote=$2
nruns=$3
scen=$4
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
trfs '#U*' /n/local
ghome=/n/local/^`{echo 'echo $HOME' | os sh}
infhome=$ghome^/.infernode
mkdir -p /lib/keyring >[2] /dev/null
bind -bc $infhome/lib/keyring /lib/keyring
mount -k /lib/keyring/serve-llm $remote /mnt/llm
/tests/p9drive.dis $model /tmp/p9/$scen /tmp/p9/tools.json /tmp/p9/system.txt $nruns
