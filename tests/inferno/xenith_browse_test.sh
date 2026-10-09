#!/dis/sh.dis
#
# Xenith browses: a URL looked at (B3) opens a browser window, named by
# the page's URL, its text the page's, the page drawn over it, Back Fwd
# Reload in its tag.  Get goes to the URL named in the tag (the tag is
# the address bar); Back and Fwd go through what the window has shown;
# Render shows the page's text and the page again.  The pages are
# file: URLs (tests/xenith/html), so no network is needed.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_browse_test.sh starts Xenith and runs this.

load std

XENITH=/mnt/xenith
INDEX=file:///tests/xenith/html/index.html
PAGE2=file:///tests/xenith/html/page2.html

if {! ftest -f $XENITH/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

failed=0

fn pass {
	echo 'PASS:' $*
}

fn fail {
	echo 'FAIL:' $*
	failed=1
}

# The id of the window named $1, or nothing
fn winof {
	name := $1
	for l in ${split '
' "{cat $XENITH/index}} {
		fl := ${split ' 	' $l}
		if {~ ${index 6 $fl} $name} {
			echo ${index 1 $fl}
		}
	}
}

# Wait (up to ten seconds) until window $1's body has $2 in it
fn waitbody {
	wid := $1
	pat := $2
	found := 0
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {~ $found 0} {
			if {grep -s $pat $XENITH/$wid/body >[2] /dev/null} {
				found = 1
			} {
				sleep 1
			}
		}
	}
	~ $found 1
}

# Execute $2 in window $1, as button 2 on it: the word is put at the
# start of the body (the addr file's address, 0 when it is opened),
# then executed there
fn execute {
	wid := $1
	cmd := $2
	echo -n '#0' > $XENITH/$wid/addr
	echo -n $cmd^' ' > $XENITH/$wid/data
	n := `{echo -n $cmd | wc -c}
	echo 'MX0 '^$n > $XENITH/$wid/event
}

# a URL looked at, from a scratch window
id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
echo -n $INDEX > $XENITH/$id/body
n=`{echo -n $INDEX | wc -c}
echo 'ML0 '^$n > $XENITH/$id/event
echo clean > $XENITH/$id/ctl
echo delete > $XENITH/$id/ctl

w=()
for i in 1 2 3 4 5 {
	if {~ $#w 0} {
		w=`{winof $INDEX}
		sleep 1
	}
}
if {~ $#w 0} {
	fail 'no browser window for' $INDEX
	raise 'fail:tests failed'
}
if {waitbody $w 'Hello from the index'} {
	pass 'a URL opens as a browser window with the page text'
} {
	fail 'the page text never arrived'
}
tag="{cat $XENITH/$w/tag}
if {~ $tag *'Back Fwd Reload'*} {
	pass 'Back Fwd Reload in the tag'
} {
	fail 'tag:' $tag
}
img=`{cat $XENITH/$w/image}
if {! ~ $#img 0} {
	pass 'the page is drawn over the text'
} {
	fail 'no page drawn'
}

# the tag is the address bar: a name there, then Get
echo 'name '^$PAGE2 > $XENITH/$w/ctl
echo get > $XENITH/$w/ctl
if {waitbody $w 'Page two'} {
	pass 'Get goes to the URL in the tag, in the same window'
} {
	fail 'Get did not go to' $PAGE2
}

execute $w Back
if {waitbody $w 'Hello from the index'} {
	pass 'Back goes to the page before'
} {
	fail 'Back did not'
}
w2=`{winof $INDEX}
if {~ $w2 $w} {
	pass 'and names the window by it'
} {
	fail 'window name after Back:' `{winof $INDEX}
}

execute $w Fwd
if {waitbody $w 'Page two'} {
	pass 'Fwd goes forward again'
} {
	fail 'Fwd did not'
}

execute $w Render
img=`{cat $XENITH/$w/image}
if {~ $#img 0 && grep -s 'Page two' $XENITH/$w/body} {
	pass 'Render shows the page text'
} {
	fail 'Render did not leave the page:' $img
}
execute $w Render
img=`{cat $XENITH/$w/image}
if {! ~ $#img 0} {
	pass 'and Render again the page'
} {
	fail 'Render did not bring the page back'
}

# Over HTTP, through webfs (which Xenith starts): the same page, served
# on the loopback by the host side, with its style sheet
if {ftest -s /tmp/xenith_browse.port} {
	port=`{cat /tmp/xenith_browse.port}
	HTTP=http://127.0.0.1:^$port^/index.html
	id=`{cat $XENITH/new/ctl}
	id=${index 1 $id}
	echo -n $HTTP > $XENITH/$id/body
	n=`{echo -n $HTTP | wc -c}
	echo 'ML0 '^$n > $XENITH/$id/event
	echo clean > $XENITH/$id/ctl
	echo delete > $XENITH/$id/ctl
	h=()
	for i in 1 2 3 4 5 {
		if {~ $#h 0} {
			h=`{winof $HTTP}
			sleep 1
		}
	}
	if {! ~ $#h 0 && waitbody $h 'Hello from the index'} {
		pass 'an http: URL is browsed, through webfs'
	} {
		fail 'the http: page did not load:' $HTTP
	}
} {
	echo 'SKIP: no HTTP server (python3)'
}

if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'
