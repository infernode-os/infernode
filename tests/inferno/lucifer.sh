#!/dis/sh.dis
load std
luciuisrv
sleep 1
echo 'activity create Test' > /mnt/ui/ctl
cat /mnt/ui/activity/current
cat /mnt/ui/activity/0/label
echo 'role=human text=Hello world' > /mnt/ui/activity/0/conversation/ctl
cat /mnt/ui/activity/0/conversation/0
ls /mnt/ui/activity/0/
echo 'resource add path=/n/sensors/adsb label=ADS-B type=sensor status=streaming latency=2' > /mnt/ui/activity/0/context/ctl
cat /mnt/ui/activity/0/context/resources/0
echo 'create id=air-pic type=radar label=Air Picture' > /mnt/ui/activity/0/presentation/ctl
ls /mnt/ui/activity/0/presentation/
cat /mnt/ui/activity/0/presentation/air-pic/type
echo 'warning Peer requesting attention' > /mnt/ui/notification
cat /mnt/ui/notification
echo PASS
