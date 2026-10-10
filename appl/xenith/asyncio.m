Asyncio: module {
	PATH: con "/dis/xenith/asyncio.dis";

	init: fn(mods: ref Dat->Mods);

	# Async operation messages sent to casync channel
	AsyncMsg: adt {
		pick {
			Chunk =>
				opid: int;      # Operation ID
				data: string;   # Chunk of data read
				offset: int;    # Position in file
			Progress =>
				opid: int;
				current: int;   # Bytes processed so far
				total: int;     # Total bytes (0 if unknown)
			Complete =>
				opid: int;
				nbytes: int;    # Total bytes read
				nrunes: int;    # Total runes (characters)
				err: string;    # nil on success
			Error =>
				opid: int;
				err: string;
		# a window's document (docview(2)), from work off the main loop
		DocOpened =>
				winid: int;
				gen: int;       # which opening of the window's document
				eng: Docengine;
				h: int;         # the engine's handle, or -1
				text: string;   # a binary document's text
				err: string;
		DocPainted =>
				winid: int;
				gen: int;
				n: int;         # the sheet
				scale: int;
				image: ref Draw->Image;
				err: string;
		DocEvent =>
				winid: int;
				gen: int;
				event: string;  # docengine(2): events
		TextData =>
				opid: int;      # Operation ID
				winid: int;     # Window ID for the text
				path: string;   # File path
				q0: int;        # Insert position (start of file content)
				data: string;   # Chunk of text data
				offset: int;    # Rune offset within file (cumulative)
				err: string;    # nil on success
		TextComplete =>
				opid: int;      # Operation ID
				winid: int;     # Window ID for the text
				path: string;   # File path
				nbytes: int;    # Total bytes read
				nrunes: int;    # Total runes read
				err: string;    # nil on success
		DirEntry =>
				opid: int;      # Operation ID
				winid: int;     # Window ID
				name: string;   # Entry name (with trailing / for dirs)
				isdir: int;     # 1 if directory
		DirComplete =>
				opid: int;      # Operation ID
				winid: int;     # Window ID
				path: string;   # Directory path
				nentries: int;  # Total entries read
				err: string;    # nil on success
		SaveProgress =>
				opid: int;      # Operation ID
				winid: int;     # Window ID
				written: int;   # Bytes written so far
				total: int;     # Total bytes to write
		SaveComplete =>
				opid: int;      # Operation ID
				winid: int;     # Window ID
				path: string;   # File path
				nbytes: int;    # Total bytes written
				mtime: int;     # New mtime after save
				err: string;    # nil on success
		}
	};

	# Async operation handle for cancellation
	AsyncOp: adt {
		opid: int;
		ctl: chan of int;   # Send 1 to cancel
		path: string;
		active: int;
		winid: int;         # Window ID (for image ops)
	};

	# Start async file read - returns operation handle
	asyncload: fn(path: string, q0: int): ref AsyncOp;

	# Start async text file load - returns operation handle
	asyncloadtext: fn(path: string, q0: int, winid: int): ref AsyncOp;

	# Start async directory listing - returns operation handle
	asyncloaddir: fn(path: string, winid: int): ref AsyncOp;

	# Start async file save - returns operation handle
	# Reads from buffer positions q0..q1 and writes to path
	asyncsavefile: fn(path: string, winid: int, buf: ref Bufferm->Buffer, q0, q1: int): ref AsyncOp;

	# Cancel an async operation
	asynccancel: fn(op: ref AsyncOp);

	# Check if operation is still active
	asyncactive: fn(op: ref AsyncOp): int;

	# Note: Results are sent to dat->casync channel
};
