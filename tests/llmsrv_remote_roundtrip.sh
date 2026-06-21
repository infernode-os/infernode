#!/dis/sh.dis
# Full tool_use round-trip against a REMOTE InferNode llmsrv exported over
# 9P (serve-llm) — the real distributed deployment path. Mounts the remote
# /mnt/llm with keyring auth, sets the per-session model, drives the loop.
# Args: $1=model  $2=remote (tcp!host!port)
load std

model = $1
remote = $2

mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs

# Host filesystem (for the signer keyfile under ~/.infernode/lib/keyring).
trfs '#U*' /n/local
ghome=/n/local/^`{echo 'echo $HOME' | os sh}
infhome=$ghome^/.infernode
mkdir -p /lib/keyring >[2] /dev/null
bind -bc $infhome/lib/keyring /lib/keyring

echo REMOTE: $remote  KEYFILE: /lib/keyring/serve-llm
mount -k /lib/keyring/serve-llm $remote /mnt/llm
echo MOUNT_RC: $status

echo AVAILABLE_MODELS_BEGIN
cat /mnt/llm/models >[2] /dev/null
echo AVAILABLE_MODELS_END

id=`{cat /mnt/llm/new}
echo SESSION: $id
echo MODEL_REQUESTED: $model
echo $model > /mnt/llm/$id/model
echo MODEL_SET_RC: $status

echo '[{"name":"read","description":"Read a file. Args: path","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]' > /mnt/llm/$id/tools

echo 'Use the read tool to read /tool/editor/doc, then tell me exactly what text the file contains.' > /mnt/llm/$id/ask
response=`{cat /mnt/llm/$id/ask}
echo STEP1_BEGIN
echo $response
echo STEP1_END

hasstop=no
for w in $response { if {~ $w 'STOP:tool_use'} { hasstop=yes } }
echo STEP1_STOP_TOOLUSE: $hasstop

toolline=''
for w in $response { if {~ $w 'TOOL:*'} { toolline=$w } }
toolrest=`{echo $toolline | sed 's/^TOOL://'}
toolid=`{echo $toolrest | sed 's/:.*//'}
echo STEP1_TOOLID: $toolid

hasmangle=no
for w in $response { if {~ $w '*\\/tool*'} { hasmangle=yes } }
echo STEP1_SLASH_MANGLED: $hasmangle

echo 'TOOL_RESULTS
'^$toolid^'
The file /tool/editor/doc contains the text: HELLO-FROM-INFERNODE
---' > /mnt/llm/$id/ask
response2=`{cat /mnt/llm/$id/ask}
echo STEP2_BEGIN
echo $response2
echo STEP2_END

hasend=no
for w in $response2 { if {~ $w 'STOP:end_turn'} { hasend=yes } }
echo STEP2_END_TURN: $hasend

sawmarker=no
for w in $response2 { if {~ $w '*HELLO-FROM-INFERNODE*'} { sawmarker=yes } }
echo STEP2_USED_RESULT: $sawmarker
echo DONE
