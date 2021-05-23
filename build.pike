#!/usr/local/bin/pike
/*
To build the full Frozen OST, you will need FFMPEG, sox, and of course Pike. The other files are all listed in the track list.
Note that the trackid subtitles file is used by the FlemishFrozen project, so a basic build of this project is needed before that works.

A full build will chug and chug and CHUG as it builds quite a few separate pieces. Currently there's no -j option to
parallelize, but several of the steps are capable of using multiple CPU cores intrinsically.
*/

//Emit output iff in verbose mode
//Note that it'll still evaluate its args even in non-verbose mode, for consistency.
#ifdef VERBOSE
constant verbose=write;
#else
void verbose(mixed ... args) { };
#endif

void exec(array(string) cmd)
{
	int t=time();
	write("%{%s %}\n",Process.sh_quote(cmd[*]));
	Process.create_process(cmd)->wait();
	float tm=time(t);
	if (tm>5.0) verbose("-- done in %.2fs\n",tm);
}

/* TODO: Add auto-fill-in with shine-through option. Anywhere there's a gap
(ie when pos>lastpos), create a fill-in track, effectively "999 :: [L::]". */

/* Build modes are, by default, selected by a keyword.

Each build mode specifies a number of sound tracks, which will be incorporated into the resulting
movie in order. (The first one listed will be the default playback track.) If the sound track is
"c", it will be an exact copy of the original (mapped in directly). Otherwise, it consists of any
number of the following letters, specifying inclusions:

w: Words tracks (those tagged [Words]; automatically excludes [Instrumental] tracks)
9: Shine-through tracks (note that they can still be excluded by a Words/Instrumental tag)
s: Synchronization track (the original sound track mixed in at reduced volume)
m: Messy tracks (those tagged [Mess]; automatically excludes [NonMess] tracks)
l: Include the original on the left channel, and everything listed here on the right channel
r: The converse - original audio on the right, OST mix on the left. Good for synchronization.
*/
constant trackdesc=([
	"":"Instrumental","9":"Instrumental + shinethrough (best listening)",
	"w":"Words","w9":"Words + shinethrough (best listening)",
	"m":"Instrumental + messy (most pure)","m9":"Instrumental + messy + shinethrough",
	"wm":"Words + messy","wm9":"Words + messy + shinethrough",
	"s":"Instrumental + sync","ws":"Words + sync",
	"s9":"Instrumental + shinethrough + sync","ws9":"Words + shinethrough + sync",
	"sm":"Instrumental + sync + messy","wsm":"Words + sync + messy",
	"sm9":"Instrumental + shinethrough + sync + messy","wsm9":"Words + shinethrough + sync + messy",
	"rm":"Instrumental l/r sync","wrm":"Words l/r sync",
	"rm9":"Instrumental + shinethrough l/r sync","wrm9":"Words + shinethrough l/r sync",
]);
constant modes=([
	"": ({"9", "w9", "c"}), //Default build
	"9c": ({"9", "c"}), "wc": ({"w9", "c"}), //Build only one of the two main tracks
	"lr": ({"rm", "m", "c"}), //L/R sync
	"mini": ({"9", "w9"}), "imini": ({"9"}), "wmini": ({"w9"}), //Quicker build, much quicker if you take only one track
	"sync": ({"s9", "ws9"}), "isync": ({"s9"}), "wsync": ({"ws9"}), //Include sync track
	"lr": ({"rm", "wrm"}), "ilr": ({"rm"}), "wlr": ({"wrm"}), //Left/Right sync
	"full": ({ }), //Everything we can think of! Provided elsewhere as neither sort() nor Array.array_sort() can be used in a constant definition.
]);

//Convert a millisecond time position into .srt format: HH:MM:SS,mmm (comma between seconds and milliseconds)
string srttime(int tm)
{
	return sprintf("%02d:%02d:%02d,%03d",tm/3600000,(tm/60000)%60,(tm/1000)%60,tm%1000);
}

//Convert a millisecond time position into sss.mmm
string mstime(int tm)
{
	return sprintf("%d.%03d",tm/1000,tm%1000);
}

//Write everything on one line, thus disposing of the unwanted spam :)
void onelineoutput(string data) {write(replace(data,"\n","\r"));}
mapping oneline=(["stderr":onelineoutput]);

//Parser for track file
string trackdata;
string|array low_next() {
	//Lexer for trackdata: basic tokens
	if (trackdata == "") return "";
	if (sscanf(trackdata, "%*[ ];%*[^\n]%s", trackdata)) /*return ({"comment", 0})*/; //Comments get suppressed entirely (we'll fall through and return EOL)
	if (sscanf(trackdata, "%[\n]%s", string nl, trackdata) && nl != "") return ({"EOL", nl});
	if (sscanf(trackdata, "%[0-9]%s", string digits, trackdata) && digits != "") return ({"#digits", digits});
	if (sscanf(trackdata, "%[A-Z_a-z]%s", string alpha, trackdata) && alpha != "") return ({"atom", alpha});
	if (sscanf(trackdata, "%[ \t]%s", string ws, trackdata) && ws != "") return " "; //Treat all non-EOL whitespace as a single space
	sscanf(trackdata, "%1s%s", string char, trackdata); return char;
}
array magicseq = ({"EOL", "atom", ':'});
int magicidx = 1; //Can skip the EOL at start of stream
string|array next() {
	//Magic token sequence that leads to an untokenized bare string
	//It's kinda like entering a cheat code.
	if (magicidx == sizeof(magicseq) && sscanf(trackdata, "%[^\n;]%s", string value, trackdata)) {
		magicidx = 0;
		return ({"value", String.trim(value)});
	}
	string|array ret = low_next();
	if (ret == "") return "";
	if (ret[0] == magicseq[magicidx]) ++magicidx;
	else magicidx = ret[0] == magicseq[0];
	return ret;
}
//For lexer debugging, switch from using next to using shownext
string|array shownext() {mixed ret = next(); write("Got next [%d]:%{ %O%} ==> %O\n", magicidx, Array.arrayify(ret), trackdata[..5]); return ret;}

//Parser handlers
//Config variables, can be set with directives. If set to 0 here, must be
//defined in the file, otherwise this will be the default. If not named,
//the variable cannot be set.
mapping vars = ([
	"MovieSource": 0,
	"OST_dir": 0,
	"OST_pat": 0,
	"OutputFile": 0,
	"IntermediateDir": "./",
	"WordsFile": "", //Optional - if absent, words-and-tracks won't be made.
	"ShinethroughVolume": "", //Optional - if absent, shinethrough volume isn't changed
]);
array tracks = ({ });
void setvar(string var, string colon, string val) {
	if (!has_index(vars, var)) error("Unknown variable %O\n", var);
	vars[var] = val;
}
mixed maketrack(string tracknum, string _1, int starttime, string|void _2, string|void _3, mapping|void args, string|void _4) {
	return ({tracknum, starttime, args || ([])});
}
array collection(mixed ... thing) {return thing;} //Gather all its args into a collection
array gather(array prev, string sep, mixed thing) {return prev + ({thing});} //Recursively gather more
//Data type handling
int seconds(string digits) {return 1000 * (int)digits;}
int milliseconds(string _, string digits) {return (int)((digits + "000")[..2]);}
int sec_milli(string s, string _, string m) {return seconds(s) + milliseconds(".", m);}
constant ABUT = 1<<30; int time_abut() {return ABUT;} //Sentinel to mean "up to the next" or "from where the prev ended"
int time_minsec(string m, string _, int time) {return time + 60000 * (int)m;}
int time_hms(string h, string _1, string m, string _2, int time) {return time + 60000 * (int)m + 3600000 * (int)h;}
mixed take2(mixed _, mixed ret) {return ret;}
mapping tag(string atom, mixed|void val) {return ([atom[..0]: undefinedp(val) ? 1 : val]);}
mapping tags(mapping t1, string _, mapping t2) {return t1 | t2;}

int main(int argc,array(string) argv)
{
	if (argc>1 && argv[1]=="san") exit(0,"San-check passed\n"); //Does it even compile? Very quick check, doesn't read or write any files.
	int start=time();
	array(string) times=({ });
	string mode="";
	int ignorefrom,ignoreto;
	if (sscanf(Stdio.read_file("partialbuild")||"","%[a-z0-9] %[0-9:.] %[0-9:]",mode,string start,string len) && start && start!="")
	{
		times=({"-ss",start,"-t",len||"0:01:00"});
		foreach (start/":",string part) ignorefrom=(ignorefrom*60)+(int)part;
		foreach (times[-1]/":",string part) ignoreto=(ignoreto*60)+(int)part; ignoreto+=ignorefrom;
		ignorefrom*=1000; ignoreto*=1000; //TODO: Actually use subsecond resolution
	}
	if (argc>1 && argv[1]!="" && (modes[argv[1]] || trackdesc[argv[1]] || argv[1] == "trackusage")) mode=argv[1]; //Override mode from command line if possible; ignore unrecognized args.
	string trackfile = "tracks";
	if (sscanf(argv[0], "%*sbuild_%[A-Za-z].pike%s", string fn, string empty) && fn && empty == "") trackfile = fn;
	trackdata = Stdio.read_file(trackfile);
	Parser.LR.Parser parser = Parser.LR.GrammarParser.make_parser_from_file("tracks.grammar");
	array tracks = parser->parse(next, this) - ({0});
	array missing = ({ }); foreach (vars; string name; string val) if (!val) missing += ({name});
	if (sizeof(missing)) exit(1, "Must have " + String.implode_nicely(missing) + " directives in tracks file\n");
	string ost_glob = replace(vars->OST_pat, (["#": "%s", "~": "*"]));
	string ost_desc = replace(vars->OST_pat, (["#": "%*s", "*": "%*s", "~": "%s"]));
	string intermediatedir = vars->IntermediateDir;
	if (intermediatedir == "") intermediatedir = "./";
	else if (!has_suffix(intermediatedir, "/")) intermediatedir += "/";
	Stdio.mkdirhier(intermediatedir);

	//Intermediate file names. Will be created inside the IntermediateDir directory ("." if unspecified).
	string movie = intermediatedir + "Original movie.mkv"; //Copied local from moviesource
	string modified_soundtrack = intermediatedir + "MovieSoundTrack_%s.wav"; //Movie soundtrack with some modification, keyword in the %s
	string tweaked_soundtrack = sprintf(modified_soundtrack, "bitratefixed"); //Converted down to 2 channels and 44KHz
	string alternate_soundtrack = sprintf(modified_soundtrack, "altchannel"); //A different channel pair
	string left_soundtrack = sprintf(modified_soundtrack, "leftonly"); //With the right channel muted...
	string right_soundtrack = sprintf(modified_soundtrack, "rightonly"); //or the left channel muted.
	string combined_soundtrack = intermediatedir + "soundtrack_%s.wav"; //All the individual track files (gets the mode string inserted)
	//Automatically-created output files (in the current directory). TODO: Let these be specified by the config file.
	constant trackidentifiers = "audiotracks.srt"; //Surtitles file identifying each track as it comes up
	constant wordsandtracks = "words_and_tracks.srt"; //Merge of the above with the WordsFile

	if (mode == "trackusage")
	{
		//Special: Instead of actually building anything, just run through the tracks
		//and figure out which parts of the original files haven't been used. Contains
		//code copied from the below; full deduplication is probably not easy.
		//As of 20141025, the unused sections of Frozen are:
		//115: 34.500->end
		//131: 0.000-26.000
		//222: 0.000-5.250
		//There are a number of completely unused files, including outtakes, the words
		//versions of tracks available instrumentally, and the credits song (which for
		//some reason doesn't seem to fit, so there's a comments-only line in tracks).
		array ostfiles = glob(sprintf(ost_glob, "*"), get_dir(vars->OST_dir));
		mapping(string:array) partialusage = ([]);
		foreach (tracks, [string prefix, int pos, mapping tags])
		{
			if (prefix == "999" || prefix == "99") continue; //Ignore shine-through segments
			ostfiles -= glob(sprintf(ost_glob, prefix), ostfiles);
			if (!tags->S && !tags->L) continue; //Easy
			partialusage[prefix] += ({({tags->S && tags->S[0], tags->L && tags->L[0]})});
		}
		write("Unused files:\n%{%3.3s: all\n%}", sort(ostfiles));
		foreach (sort(indices(partialusage)), string track)
		{
			int doneto = 0;
			array(string) gaps = ({ });
			foreach (sort(partialusage[track]), [int start, int len])
			{
				if (start - doneto > 1000) gaps += ({sprintf("%s-%s", mstime(doneto), mstime(start))}); //Ignore gaps of up to a second, which are usually just skipping over the silence between sections
				if (len) doneto = start + len; else doneto = -1; //There shouldn't be anything following a length-less entry
			}
			if (doneto != -1) gaps += ({sprintf("%s->end", mstime(doneto))});
			if (sizeof(gaps)) write("%s: %s\n", track, gaps*", ");
		}
		return 0;
	}
	array(string) trackdefs=modes[mode];
	if (!trackdefs)
	{
		if (trackdesc[mode]) trackdefs=({mode});
		else exit(0,"Unrecognized mode %O\n",mode);
	}
	if (mode=="full") trackdefs=sort(indices(trackdesc)) + ({"c"}); //Can't be done in the constant as sort() mutates its argument.
	if (!file_stat(movie))
	{
		if (has_suffix(vars->MovieSource, ".mkv"))
		{
			write("Copying %s from %s\n", movie, vars->MovieSource);
			Stdio.cp(vars->MovieSource, movie);
		}
		else
		{
			write("Creating %s from %s\n", movie, vars->MovieSource);
			exec(({"ffmpeg", "-i", vars->MovieSource, movie}));
		}
	}
	if (!file_stat(tweaked_soundtrack))
	{
		mapping metadata = Standards.JSON.decode(Process.run(({"ffprobe",
			"-print_format", "json", "-show_streams",
			"-select_streams", "a", //Show audio streams only, so we don't have to filter them
			"-v", "quiet",
			movie}))->stdout);
		if (!mappingp(metadata) || !arrayp(metadata->streams)) exit(1, "Bad output format from ffprobe, cannot continue\n");
		if (!sizeof(metadata->streams)) exit(1, "No audio tracks in %s\n", movie);
		write("Rebuilding %s (downmixing and fixing bitrate from %s)\n", tweaked_soundtrack, movie);
		string vol = vars->ShinethroughVolume != "" ? ", volume=" + vars->ShinethroughVolume : "";
		//The default soundtrack file will be the side channels if available, else the rear.
		//If both are available, alternate_soundtrack will exist too.
		//TODO: Should I just let ffmpeg figure it out and always ask for both BL/BR and SL/SR?
		//Or should the tracks file specify channel selection?
		//Other alternatives to consider: "[0:1]channelsplit=channel_layout=7.1:channels=BL|BR[lf][rf];[lf][rf]amerge=inputs=2[aout]"
		//or "channelsplit=channel_layout=7.1:channels=BL|BR[lf][rf];[lf][rf]amerge=inputs=2[aout]"
		switch (metadata->streams[0]->channel_layout)
		{
			case "5.1":
				write("Rebuilding %s (selecting rear channels from %s)\n", tweaked_soundtrack, movie);
				exec(({"ffmpeg", "-y", "-i", movie, "-af", "pan=stereo|c0=BL|c1=BR" + vol, "-ar", "44100", tweaked_soundtrack}));
				break;
			case "5.1(side)":
				write("Rebuilding %s (selecting side channels from %s)\n", tweaked_soundtrack, movie);
				exec(({"ffmpeg", "-y", "-i", movie, "-af", "pan=stereo|c0=SL|c1=SR" + vol, "-ar", "44100", tweaked_soundtrack}));
				break;
			case "7.1":
				write("Rebuilding %s (selecting side channels from %s)\n", tweaked_soundtrack, movie);
				exec(({"ffmpeg", "-y", "-i", movie, "-af", "pan=stereo|c0=SL|c1=SR" + vol, "-ar", "44100", tweaked_soundtrack}));
				write("Rebuilding %s (selecting rear channels from %s)\n", alternate_soundtrack, movie);
				exec(({"ffmpeg", "-y", "-i", movie, "-af", "pan=stereo|c0=BL|c1=BR" + vol, "-ar", "44100", alternate_soundtrack}));
				break;
			default:
				werror("WARNING: Unknown channel layout %s, using default downmix only\n", metadata->streams[0]->channel_layout);
			case "stereo": //Default downmix is all we can get for stereo. (No warning needed.)
				exec(({"ffmpeg", "-y", "-i", movie, "-af", "null" + vol, "-ac", "2", "-ar", "44100", tweaked_soundtrack}));
				break;
		}
	}
	array prevtracks;
	catch {prevtracks = Standards.JSON.decode(Stdio.read_file(intermediatedir + "prevtracks"));};
	if (!arrayp(prevtracks)) prevtracks = ({ });
	int trackdelta = sizeof(tracks) - sizeof(prevtracks); //Positive means some have been added, negative deleted
	if (trackdelta) {
		//Attempt to intelligently pair up old and new tracklists in the event
		//that there's been a single insertion or deletion somewhere in the
		//middle of the array. If there have been multiple blocks inserted, or
		//insertions in one place and deletions in another, or anything else
		//more complicated, this diff won't catch it, and the naive handling
		//below will end up deleting and recreating a bunch of tracks that
		//could have been just mv'd to their new positions - wasted work but
		//the result is definitely going to be correct.
		int rear;
		for (rear = 1; rear <= sizeof(tracks) && rear <= sizeof(prevtracks); ++rear) {
			//Note that equal() handles arrays the way we want it to,
			//but `==() would check identity.
			if (!equal(tracks[-rear], prevtracks[-rear])) break;
		}
		if (trackdelta > 0) {
			//Insert shims to denote the places where new tracks get made
			prevtracks = prevtracks[..<rear-1] + ({({"", 0, 0})}) * trackdelta + prevtracks[<rear-2..];
			for (int t = sizeof(tracks) - 1; t > sizeof(tracks) - rear; --t)
				mv(sprintf("%s%02d.wav", intermediatedir, t - trackdelta),
					sprintf("%s%02d.wav", intermediatedir, t));
		}
		else {
			//If multiple tracks were removed near (or at) the end, we might
			//have left some behind. Shouldn't be a problem; they'll just
			//linger in the cache until something needs to dispose of them.
			//Remove the nuked tracks (the files have already been mv'd)
			prevtracks = prevtracks[..<rear-1-trackdelta] + prevtracks[<rear-2..];
			for (int t = sizeof(tracks) - rear + 1; t < sizeof(tracks); ++t)
				mv(sprintf("%s%02d.wav", intermediatedir, t - trackdelta),
					sprintf("%s%02d.wav", intermediatedir, t));
		}
		//We've moved cache files around, so be sure to save the prevtracks, in case
		//the build gets halted part way. Cache desynchronization is a PAIN.
		Stdio.write_file(intermediatedir + "prevtracks", Standards.JSON.encode(tracks - ({""}), 7));
	}
	array(string) dir = get_dir(intermediatedir), ostfiles = get_dir(vars->OST_dir);
	int changed;
	array(array(string)) tracklist=allocate(sizeof(trackdefs),({ }));
	//Positions are in milliseconds
	int lastpos=0;
	int overlap=0,gap=0; int abuttals;
	Stdio.File srt=Stdio.File(trackidentifiers,"wct");
	int srtcnt=0;
	foreach (tracks; int i; [string source, int startpos, mapping tags])
	{
		string outfn=sprintf("%02d.wav",i);
		if (startpos == ABUT) verbose("%s: placing at %s\n", outfn, mstime(tracks[i][1] = startpos = lastpos)); //Explicit abuttal - patch in the actual time, for the use of prevtracks
		if (source == "") {rm(intermediatedir + outfn); write("Removing %s\n", outfn); continue;} //Track list shortened - remove the last N tracks.
		source = (["99": "999", "98": "998"])[source] || source;

		string prefix = source;
		int partial_start, partial_len;
		if (prefix == "999" || prefix == "998") prefix += "S" + (partial_start = startpos);
		if (tags->S) prefix += "S" + (partial_start = tags->S[0]);
		if (tags->L) {
			//"Length up to where the next one starts"
			//Ignores any tempo shift - don't use both together.
			//Obviously incompatible with the next track starting at ::
			if (tags->L[0] == ABUT) partial_len = tracks[i + 1][1] - startpos;
			else partial_len = tags->L[0];
			prefix += "L" + partial_len;
		}

		if (!equal(tracks[i], prevtracks[i]) || !has_value(dir,outfn)) //Changed, or file doesn't currently exist? Build.
		{
			rm(intermediatedir + outfn);

			//Find and maybe create the .wav version of the input file we want
			array(string) in=glob(prefix+" *.wav",dir); string infn;
			if (!sizeof(in))
			{
				string fn;
				if (source=="999") {fn=tweaked_soundtrack; infn=prefix+" movie sound track.wav";}
				else if (source=="998") {fn=alternate_soundtrack; infn=prefix+" movie alt sound track.wav";}
				else
				{
					fn = glob(sprintf(ost_glob, source), ostfiles)[0]; //If it doesn't exist, bomb with a tidy exception.
					sscanf(fn, ost_desc, string basename);
					infn=prefix+" "+basename+".wav";
					fn = vars->OST_dir + "/" + fn;
				}
				write("Creating %s from MP3\n",infn);
				array(string) args=({"ffmpeg","-i",fn});
				if (partial_start) args += ({"-ss", mstime(partial_start)});
				if (partial_len) args += ({"-t", mstime(partial_len)});
				exec(args + ({intermediatedir + infn}));
				dir=get_dir(intermediatedir); if (!has_value(dir,infn)) exit(1,"Was not able to create %s - exiting\n",infn);
			}
			else infn=in[0];

			write("%s %s: %s - %O\n", prevtracks[i][0] == "" ? "Creating" : "Rebuilding", outfn, mstime(startpos), infn);
			//eg: sox 111* 01.wav delay 0:00:05 0:00:05
			array(string) args = ({"sox", intermediatedir + infn, intermediatedir + outfn});
			if (tags->T)
			{
				//When the tempo shift is very close to 1.0, the -l parameter
				//gives better results (less audible distortion) than -m does,
				//but otherwise, definitely use -m. Trouble is, the docs aren't
				//very clear on what "very close" is; all I know is, .999 is
				//indeed close, and 1.1 isn't. Experimentation suggests that
				//even .995 isn't close enough; at .998 and 1.002, both forms
				//produce easily acceptable results, so that's what I'm using
				//as my cut-over point. If it's nearer than that (and since
				//they both work just fine at that figure, I'm not bothered by
				//floating-point issues and platform differences), I use -l.
				args += ({"tempo", (tags->T[0] > 998 && tags->T[0] < 1002) ? "-l" : "-m", mstime(tags->T[0])});
			}
			if (tags->F) args += ({"fade"}) + (array(string))(tags->F[*] / 1000);
			exec(args + ({"delay", mstime(startpos), mstime(startpos)}));
			changed = 1;
		}
		//Query the file's duration to get its effective end position
		sscanf(Process.run(({"sox", "--i", "-D", intermediatedir + outfn}))->stdout, "%d.%s", int sec, string ms);
		int endpos = sec*1000 + (int)(ms+"000")[..2];
		if (!tags->I && !tags->N) //Tracks tagged [Instrumental] exist only as alternates for corresponding [Words] tracks. Don't update lastpos, don't create subtitles records.
		{
			if (startpos>lastpos)
			{
				verbose("%s: gap %s -> %s\n",outfn,mstime(startpos-lastpos),mstime(gap+=startpos-lastpos));
				//TODO: Auto-shine-through??
				srt->write("%d\n%s --> %s\n%[1]s - %[2]s\n(%s seconds)\n\n",++srtcnt,srttime(lastpos),srttime(startpos),mstime(startpos-lastpos));
				lastpos=startpos;
			}
			else if (startpos==lastpos) verbose("%s: abut (#%d)\n",outfn,++abuttals);
			else verbose("%s: overlap %s -> %s\n",outfn,mstime(lastpos-startpos),mstime(overlap+=lastpos-startpos));
			lastpos=endpos;
			string desc = source;
			array(string) files = glob(sprintf(ost_glob, source), ostfiles);
			if (sizeof(files)) sscanf(files[0], ost_desc, desc);
			if (source == "999") desc="Shine-through";
			if (source == "998") desc="Shine-through (alt)";
			srt->write("%d\n%s --> %s\n%[1]s - %[2]s\n%02d: %s\n\n",++srtcnt,srttime(startpos),srttime(endpos),i,desc);
		}
		if (ignoreto && ignoreto<startpos) continue; //Can't have any effect on the resulting sound, so elide it
		if (endpos<ignorefrom) continue;
		foreach (trackdefs;int i;string t)
		{
			if (has_value(t,'w') ? tags->I : tags->W) continue;
			if (has_value(t,'m') ? tags->N : tags->M) continue;
			if (!has_value(t,'9') && (<"999", "998">)[source]) continue;
			tracklist[i] += ({intermediatedir + outfn});
		}
	}
	write("Total gap: %s\nTotal abutting tracks: %d\nTotal overlap: %s\nFinal position: %s\nNote that these figures may apply to only the beginning of the movie.\n",mstime(gap),abuttals,mstime(overlap),mstime(lastpos));
	if (changed) rm(sprintf("%s%s", intermediatedir, glob(sprintf(combined_soundtrack,"*"),get_dir(intermediatedir))[*])[*]);
	array(string) inputs = ({"-i", movie}), map = ({"-map","0:v"});
	foreach (trackdefs;int i;string t)
	{
		if (t=="c") {map+=({"-map","0:a:0","-c:a:"+(sizeof(inputs)/2-1),"copy"}); continue;} //Easy. No input, just another thing to map in.
		if (has_value(t,'s')) tracklist[i]+=({tweaked_soundtrack});
		string soundtrack=sprintf(combined_soundtrack,t);
		if (!file_stat(soundtrack))
		{
			write("Rebuilding %s (%d/%d) from %d parts\n",soundtrack,i+1,sizeof(trackdefs),sizeof(tracklist[i]));
			int tm=time();
			array trim=ignoreto?({"trim","0",mstime(ignoreto)}):({ }); //If we're doing a partial build, cut it off at the ignore position to save processing.
			array(string) moreargs=({ });
			array(string) parts=({soundtrack}); //More than one part causes temporary build to the first track, then combining of all parts into the final
			//TODO: Dedup these two
			if (has_value(t,'l'))
			{
				if (!file_stat(left_soundtrack))
				{
					write("Rebuilding %s (muting channel from %s)\n",left_soundtrack,tweaked_soundtrack);
					exec(({"sox","-S",tweaked_soundtrack,left_soundtrack,"remix","-","0"}));
				}
				parts=({sprintf(combined_soundtrack,t+"!"),left_soundtrack});
				moreargs+=({"remix","0","-v.5"});
			}
			if (has_value(t,'r'))
			{
				if (!file_stat(right_soundtrack))
				{
					write("Rebuilding %s (muting channel from %s)\n",right_soundtrack,tweaked_soundtrack);
					exec(({"sox","-S",tweaked_soundtrack,right_soundtrack,"remix","0","-"}));
				}
				parts=({sprintf(combined_soundtrack,t+"!"),right_soundtrack});
				moreargs+=({"remix","-v.5","0"});
			}
			//SoX refuses to mix one track, even if it's doing other effects. So remove the -m switch when there's only one track.
			array(string) mixornot=({"-m"})*(sizeof(tracklist[i])>1);
			Process.run(({"sox","-S"})+mixornot+({"-v",".5"})+tracklist[i]/1*({"-v",".5"})+({parts[0]})+trim+moreargs,oneline);
			if (sizeof(parts)>1) {write("\n"); Process.run(({"sox","-S","-m"})+parts+({soundtrack})+trim,oneline);}
			write("\n-- done in %.2fs\n",time(tm));
		}
		int id=sizeof(inputs)/2; //Count the inputs prior to adding this one in - map identifiers are zero-based.
		map+=({"-map",id+":a:0","-metadata:s:a:"+(id-1),"title="+(trackdesc[t]||"Soundtrack: "+t)});
		inputs+=({"-i",soundtrack});
	}
	if (vars->WordsFile && file_stat(vars->WordsFile) && file_stat("../shed/srtzip.pike")) catch
	{
		//Merge the words file with the track IDs file - requires my shed repo for srtzip.pike
		object srtzip = (object)"../shed/srtzip.pike";
		srtzip->main(7, ({"srtzip.pike", "--clobber", "--index", "--reposition",
			vars->WordsFile, trackidentifiers, wordsandtracks}));
	};
	rm(vars->OutputFile);
	exec(({"ffmpeg"}) + inputs + map + times + ({"-c:v", "copy", vars->OutputFile}));
	Stdio.write_file(intermediatedir + "prevtracks", Standards.JSON.encode(tracks - ({""}), 7));
	write("Total time: %.2fs\n", time(start));
}
