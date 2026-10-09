#!/dis/sh.dis
#
# Xenith browses: a URL looked at (B3) opens a browser window, named by
# the page's URL, its text the page's, the page drawn over it, Back Fwd
# Reload in its tag.  Get goes to the URL named in the tag (the tag is
# the address bar); Back and Fwd go through what the window has shown;
# Render shows the page's text and the page again; a form's field
# clicked takes the keyboard, and Return submits it (the click and the
# keys injected through #m/pointer and #c/keyboard).  A window's page is
# served as files, as Charon's is: its web file names where it is
# posted, and a form filled in and submitted there shows in the window.
# The pages are
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

# A form: a click in its field (which fills the page) gives it the
# keyboard, typing fills it in, Return submits it
SEARCH=file:///tests/xenith/html/search.html
id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
echo -n $SEARCH > $XENITH/$id/body
n=`{echo -n $SEARCH | wc -c}
echo 'ML0 '^$n > $XENITH/$id/event
echo clean > $XENITH/$id/ctl
echo delete > $XENITH/$id/ctl
f=()
for i in 1 2 3 4 5 {
	if {~ $#f 0} {
		f=`{winof $SEARCH}
		sleep 1
	}
}
if {~ $#f 0} {
	fail 'the form page did not open'
} {
	echo growfull > $XENITH/$f/ctl
	sleep 1
	echo -n 'm400 400 1' > '#m/pointer'
	echo -n 'm400 400 0' > '#m/pointer'
	sleep 1
	echo -n 'plan9' > '#c/keyboard'
	sleep 1
	echo > '#c/keyboard'
	if {waitbody $f 'The results page'} {
		pass 'a form field typed into and submitted with Return'
	} {
		fail 'the form was not submitted'
	}
	r=`{winof 'file:///tests/xenith/html/result.html?q=plan9'}
	if {~ $r $f} {
		pass 'with what was typed: result.html?q=plan9'
	} {
		fail 'the result window:' `{grep result $XENITH/index}
	}
}

# The page as files: posted where the window's web file says
id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
web=`{cat $XENITH/$id/web}
if {~ $#web 0} {
	pass 'a window that is not browsing has no page files'
} {
	fail 'a text window names page files:' $web
}
echo -n $SEARCH > $XENITH/$id/body
n=`{echo -n $SEARCH | wc -c}
echo 'ML0 '^$n > $XENITH/$id/event
echo clean > $XENITH/$id/ctl
echo delete > $XENITH/$id/ctl
g=()
for i in 1 2 3 4 5 {
	if {~ $#g 0} {
		g=`{winof $SEARCH}
		sleep 1
	}
}
web=`{cat $XENITH/$g/web}
if {~ $web '#sxenith/'^$g} {
	pass 'a browser window''s page is posted:' $web
} {
	fail 'the web file:' $web
}
mkdir -p /tmp/xenith_browse_page
if {mount -A $web /tmp/xenith_browse_page} {
	u=`{cat /tmp/xenith_browse_page/url}
	if {~ $u $SEARCH} {
		pass 'mounted, its url is the window''s page'
	} {
		fail 'url:' $u
	}
	# forms: form node kind name value
	f=`{grep ' q ' /tmp/xenith_browse_page/forms}
	node=${index 2 $f}
	echo set $node files > /tmp/xenith_browse_page/ctl
	echo submit 1 > /tmp/xenith_browse_page/ctl
	if {waitbody $g 'The results page'} {
		r=`{winof 'file:///tests/xenith/html/result.html?q=files'}
		if {~ $r $g} {
			pass 'a form filled in and submitted through ctl shows in the window'
		} {
			fail 'the window after the form:' `{grep result $XENITH/index}
		}
	} {
		fail 'the form submitted through ctl did not reach the window'
	}
	unmount /tmp/xenith_browse_page
} {
	fail 'cannot mount' $web
}
# (a window the user opened is closed as the user would: a 9P client
# may delete only windows it made)
execute $g Delete
sleep 1
if {ftest -e $web} {
	fail 'the page is still posted after its window closed'
} {
	pass 'and taken away when the window closes'
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
