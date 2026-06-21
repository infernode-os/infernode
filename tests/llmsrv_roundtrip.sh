#!/dis/sh.dis
# Full tool_use round-trip through native llmsrv against a real model.
# Manual diagnostic. Args: $1=model  $2=baseurl (.../v1)
load std

model = $1
url = $2

mount -ac {mntgen} /n >[2] /dev/null
bind -a '#I' /net >[2] /dev/null
ndb/cs

llmsrv -b openai -u $url -M $model -r low &
sleep 2

echo MODEL: $model
id=`{cat /mnt/llm/new}
echo SESSION: $id

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

# Flag slash-mangling in the emitted tool line, if any.
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
