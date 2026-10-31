#!/dis/sh.dis
#
# Xenith's addresses, regular expressions and sam command language,
# end to end through /mnt/xenith:
#
#	addresses written to a window's addr file, the text they select
#	read back through xdata (regx.b, the address code in ecmd.b);
#	sam commands written to its edit file, the body read back
#	(edit.b, ecmd.b, elog.b, regx.b).
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#
# tests/host/xenith_edit_test.sh starts Xenith and runs this.
#
# Expected strings are compared with ~, so they hold none of * ? [.

load std

XENITH=/mnt/xenith

if {! ftest -f $XENITH/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

failed=0

id=`{cat $XENITH/new/ctl}
id=${index 1 $id}
if {~ $#id 0} {
	raise 'skip:cannot create a window'
}
W=$XENITH/$id

TEXT='alpha
beta
gamma delta
12 apples and 345 pears
end
'

fn setbody {
	echo -n , > $W/addr
	echo -n $1 > $W/data
}

fn check {
	# check name got want
	if {~ $2 $3} {
		echo 'PASS:' $1
	} {
		echo 'FAIL:' $1
		echo '	got:' $2
		echo '	want:' $3
		failed=1
	}
}

# addr: the text an address selects in TEXT
fn addr {
	# addr name address want
	setbody $TEXT
	echo -n $2 > $W/addr
	x="{cat $W/xdata}
	check 'address '^$1 $x $3
}

# edit: the body after a sam command on TEXT
fn edit {
	# edit name command want
	setbody $TEXT
	echo $2 > $W/edit
	b="{cat $W/body}
	check 'edit '^$1 $b $3
}

# Addresses
addr 'line' '2' 'beta
'
addr 'characters' '#6,#10' 'beta'
addr 'line range' '2,3' 'beta
gamma delta
'
addr 'regexp' '/gam+a/' 'gamma'
addr 'class and repetition' '/[0-9]+/' '12'
addr 'regexp spanning a space' '/[0-9]+ pears/' '345 pears'
addr 'alternation' '/apples|pears/' 'apples'
addr 'group' '/(ap|pe)[a-z]+/' 'apples'
addr 'start of line' '/^end/' 'end'
addr 'end of line' '/[a-z]+$/' 'alpha'
addr 'regexp range' '/beta/,/delta/' 'beta
gamma delta'
addr 'line after a match' '/beta/+1' 'gamma delta
'
addr 'backwards from the end' '$-/[0-9]+/' '345'
addr 'whole file' ',' $TEXT

# Commands
edit 'substitute the first' ',s/a/A/' 'Alpha
beta
gamma delta
12 apples and 345 pears
end
'
edit 'substitute all' ',s/a/A/g' 'AlphA
betA
gAmmA deltA
12 Apples And 345 peArs
end
'
edit 'substitute a group' ',s/(ap+)les/<\1>/' 'alpha
beta
gamma delta
12 <app> and 345 pears
end
'
edit 'substitute the match' ',s/[0-9]+/&&/g' 'alpha
beta
gamma delta
1212 apples and 345345 pears
end
'
edit 'x and c' ',x/[0-9]+/c/N/' 'alpha
beta
gamma delta
N apples and N pears
end
'
edit 'x lines and i' ',x/.*\n/i/> /' '> alpha
> beta
> gamma delta
> 12 apples and 345 pears
> end
'
edit 'g in x' ',x/.*\n/g/a/d' 'end
'
edit 'v in x' ',x/.*\n/v/a/d' 'alpha
beta
gamma delta
12 apples and 345 pears
'
edit 'delete lines' '1,2d' 'gamma delta
12 apples and 345 pears
end
'
edit 'delete a match' '/beta/d' 'alpha

gamma delta
12 apples and 345 pears
end
'
edit 'append at the end' '$a/tail\n/' 'alpha
beta
gamma delta
12 apples and 345 pears
end
tail
'
edit 'insert at the start' '0i/head\n/' 'head
alpha
beta
gamma delta
12 apples and 345 pears
end
'
edit 'copy a line' '1t$' 'alpha
beta
gamma delta
12 apples and 345 pears
end
alpha
'
edit 'move a line' '1m$' 'beta
gamma delta
12 apples and 345 pears
end
alpha
'
# ^ is the start of a line, not of the word x selected: only alpha
# and beta change
edit 'a block of commands' ',x/[a-z]+/{
g/^a/c/A/
g/^b/c/B/
}' 'A
B
gamma delta
12 apples and 345 pears
end
'

# y selects what lies between the matches
setbody 'a1b22c'
echo ',y/[0-9]+/c/-/' > $W/edit
b="{cat $W/body}
check 'edit y' $b '-1-22-'

# A bad regular expression changes nothing
edit 'bad regexp' ',s/(/x/' $TEXT

# u undoes the last edit
setbody $TEXT
echo ',s/alpha/ALPHA/' > $W/edit
echo 'u' > $W/edit
b="{cat $W/body}
check 'edit u undoes' $b $TEXT

# each write to edit is its own undo step
setbody $TEXT
echo ',s/alpha/ALPHA/' > $W/edit
echo ',s/beta/BETA/' > $W/edit
echo 'u' > $W/edit
b="{cat $W/body}
check 'edit u undoes only the last edit' $b 'ALPHA
beta
gamma delta
12 apples and 345 pears
end
'

echo clean > $W/ctl
echo delete > $W/ctl

if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'
