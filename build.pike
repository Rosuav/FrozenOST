#!/usr/local/bin/pike
/*
To build the full Frozen OST, you will need avconv, sox, and of course Pike. The other files are all listed in the track list.
Note that the trackid subtitles file is used by the FlemishFrozen project, so a basic build of this project is needed before that works.

A full build will chug and chug and CHUG as it builds quite a few separate pieces. Currently there's no -j option to
parallelize, but several of the steps are capable of using multiple CPU cores intrinsically.
*/

//Intermediate file names
constant movie="Original movie.mkv"; //Copied local from moviesource
constant orig_soundtrack="MovieSoundTrack.wav"; //Direct rip from movie above
constant modified_soundtrack="MovieSoundTrack_%s.wav"; //orig_soundtrack with some modification, keyword in the %s
constant tweaked_soundtrack=sprintf(modified_soundtrack,"bitratefixed"); //Converted down to 2 channels and 44KHz
constant left_soundtrack=sprintf(modified_soundtrack,"leftonly"); //With the right channel muted...
constant right_soundtrack=sprintf(modified_soundtrack,"rightonly"); //or the left channel muted.
constant combined_soundtrack="soundtrack_%s.wav"; //All the individual track files (gets the mode string inserted)
constant trackidentifiers="trackids.srt"; //Surtitles file identifying each track as it comes up

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
	//write("%{%s %}\n",Process.sh_quote(cmd[*]));
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
	"lr": ({"rm", "m", "c"}), //L/R sync
	"mini": ({"9", "w9"}), "imini": ({"9"}), "wmini": ({"w9"}), //Quicker build, much quicker if you take only one track
	"sync": ({"9s", "ws9"}), "isync": ({"s9"}), "wsync": ({"ws9"}), //Include sync track
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
	if (argc>1 && argv[1]!="" && (modes[argv[1]] || trackdesc[argv[1]])) mode=argv[1]; //Override mode from command line if possible; ignore unrecognized args.
	string trackdata="\n"+Stdio.read_file("tracks");
	sscanf(trackdata,"%*s\nMovieSource: %s\n",string moviesource);
	sscanf(trackdata,"%*s\nOST_MP3: %s\n",string ost_mp3);
	sscanf(trackdata,"%*s\nOutputFile: %s\n",string outputfile);
	if (!moviesource || !ost_mp3 || !outputfile) exit(1,"Must have MovieSource, OST_MP3, and OutputFile identifiers in tracks file\n");
	array tracks=trackdata/"\n"; //Lines of text
	tracks=array_sscanf(tracks[*],"%[0-9] %[0-9:.] [%s]"); //Parsed: ({file prefix, start time[, tags]}) - add %*[;] at the beginning to include commented-out lines
	tracks=tracks[*]*" "-({""}); //Recombined: "prefix start[ tags]". The tags are comma-delimited and begin with a key letter.
	if (mode=="trackusage")
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
		array ostmp3dir=glob("*.mp3",get_dir(ost_mp3));
		mapping(string:array) partialusage=([]);
		foreach (tracks,string t)
		{
			array parts=t/" ";
			if (parts[0]=="999") continue; //Ignore shine-through segments
			ostmp3dir-=glob(parts[0]+"*.mp3",ostmp3dir);
			string partial_start,partial_len;
			if (sizeof(parts)>2) foreach (parts[2]/",",string tag) if (tag!="") switch (tag[0])
			{
				case 'S': partial_start=tag[1..]; break;
				case 'L': partial_len=tag[1..]; break;
				default: break;
			}
			if (!partial_start && !partial_len) continue; //Easy
			if (!partialusage[parts[0]]) partialusage[parts[0]]=({ });
			partialusage[parts[0]]+=({({(float)partial_start, partial_len && (float)partial_len})}); //Note that len will be the integer 0 if there's no length.
		}
		write("Unused files:\n%{%3.3s: all\n%}",sort(ostmp3dir));
		foreach (sort(indices(partialusage)),string track)
		{
			float doneto=0.0;
			array(string) errors=({ });
			foreach (sort(partialusage[track]),[float start,float len])
			{
				if (start-doneto>1.0) errors+=({sprintf("%f-%f",doneto||0.0,start)}); //Ignore gaps of up to a second, which are usually just skipping over the silence between sections
				if (len) doneto=start+len; else doneto=-1.0; //There shouldn't be anything following a length-less entry
			}
			if (doneto!=-1.0) errors+=({sprintf("%f->end",doneto)});
			if (sizeof(errors)) write("%s: %s\n",track,errors*", ");
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
	array prevtracks;
	catch {prevtracks=decode_value(Stdio.read_file("prevtracks"));};
	if (!prevtracks) prevtracks=({ });
	int tottracks=max(sizeof(tracks),sizeof(prevtracks));
	if (sizeof(tracks)<tottracks) tracks+=({""})*(tottracks-sizeof(tracks));
	if (sizeof(prevtracks)<tottracks) prevtracks+=({""})*(tottracks-sizeof(prevtracks));
	if (!file_stat(movie))
	{
		if (has_suffix(moviesource,".mkv"))
		{
			write("Copying %s from %s\n",movie,moviesource);
			Stdio.cp(moviesource,movie);
		}
		else
		{
			write("Creating %s from %s\n",movie,moviesource);
			exec(({"avconv","-i",moviesource,movie}));
		}
	}
	if (!file_stat(tweaked_soundtrack))
	{
		if (!file_stat(orig_soundtrack))
		{
			write("Rebuilding %s (ripping from %s)\n",orig_soundtrack,movie);
			exec(({"avconv","-i",movie,orig_soundtrack}));
		}
		sscanf(Process.run(({"sox","--i",orig_soundtrack}))->stdout,"%*sChannels%*s: %d",int channels);
		string msg; array args;
		//TODO: Figure out the actual channel pattern - currently makes assumptions based on channel count
		switch (channels)
		{
			case 2: msg=""; args=({ }); break; //2 channels - assume stereo
			case 6:
				msg=" and downmixing 5.1->stereo";
				//NOTE: It seems there's a sync error with this. Have no idea why. Is this
				//an issue only with Frozen, or is it a script bug, or a 5:1->stereo issue,
				//or what? For now, hard-coding in a short delay to resync them.
				//Downmix from 5.1 to stereo: http://forum.doom9.org/archive/index.php/t-152034.html
				args=({"remix","-m","1v0.3254,3v0.2301,5v0.2818,6v0.1627","2v0.3254,3v0.2301,5v-0.1627,6v-0.2818","delay",".1",".1"});
				break;
			default:
				werror("WARNING: Unknown channel count %d in sound track, results may be unideal\n",channels);
				msg=" and cutting channels";
				args=({"-c","2"});
				break;
		}
		write("Rebuilding %s (fixing bitrate%s from %s)\n",tweaked_soundtrack,msg,orig_soundtrack);
		exec(({"sox","-S",orig_soundtrack,"-r","44100",tweaked_soundtrack})+args);
	}
	//Figure out the changes between the two versions
	//Note that this copes poorly with insertions/deletions/moves, and will
	//see a large number of changed tracks, and simply recreate them all.
	array(string) dir=get_dir(),ostmp3dir=get_dir(ost_mp3);
	int changed;
	array(array(string)) tracklist=allocate(sizeof(trackdefs),({ }));
	//Positions are in milliseconds
	int lastpos=0;
	int overlap=0,gap=0; int abuttals;
	Stdio.File srt=Stdio.File(trackidentifiers,"wct");
	int srtcnt=0;
	for (int i=0;i<tottracks;++i)
	{
		string outfn=sprintf("%02d.wav",i);
		array parts=tracks[i]/" "; if (sizeof(parts)==1) parts+=({""});
		if (parts[1]=="::") {verbose("%s: placing at %s\n",outfn,parts[1]=mstime(lastpos)); tracks[i]=parts*" ";} //Explicit abuttal - patch in the actual time, for the use of prevtracks
		string prefix=parts[0],start=parts[1];
		int startpos; foreach (start/":",string part) startpos=(startpos*60)+(int)part; //Figure out where this track starts - will round down to 1s resolution
		startpos*=1000; if (has_value(start,'.')) startpos+=(int)((start/".")[-1]+"000")[..2]; //Patch in subsecond resolution by padding to exactly three digits
		if (tracks[i]=="") {rm(outfn); write("Removing %s\n",outfn); continue;} //Track list shortened - remove the last N tracks.
		string partial_start,partial_len,temposhift,fade;
		if (parts[0]=="999") {partial_start=parts[1]; prefix+="S"+startpos;}
		int wordsmode=0,nonwordsmode=0;
		int messmode=0,nonmessmode=0;
		if (sizeof(parts)>2) foreach (parts[2]/",",string tag) if (tag!="") switch (tag[0]) //Process the tags, which may alter the prefix
		{
			case 'S': partial_start=tag[1..]; prefix+=tag; break;
			case 'L':
				if (tag=="L::")
				{
					//"Length up to where the next one starts"
					//Ignores any tempo shift - don't use both together.
					//Obviously incompatible with the next track starting at ::
					//Code duplicated from the above
					string next=(tracks[i+1]/" ")[1];
					int nextpos; foreach (next/":",string part) nextpos=(nextpos*60)+(int)part;
					int npos=nextpos*1000; if (has_value(next,'.')) npos+=(int)((next/".")[-1]+"000")[..2];
					tag="L"+mstime(npos-startpos);
				}
				partial_len=tag[1..]; prefix+=tag;
				break;
			case 'T': temposhift=tag[1..]; break; //Note that this doesn't affect the prefix; also, the start/len times are before the tempo shift.
			case 'F': fade=tag[1..]; break; //Passed directly to "sox fade": [type] fade-in-length [stop-time [fade-out-length]])
			case 'I': nonwordsmode=1; break; //Instrumental track: skip on the "has words" soundtrack
			case 'W': wordsmode=1; break; //Words track: skip on the "all instrumental" soundtrack
			case 'N': nonmessmode=1; break; //Non-mess track: skip on the "has mess" soundtrack
			case 'M': messmode=1; break; //Messy track: skip on the "avoid mess" soundtrack
			default: break;
		}
		if (tracks[i]!=prevtracks[i] || !has_value(dir,outfn)) //Changed, or file doesn't currently exist? Build.
		{
			rm(outfn);

			//Find and maybe create the .wav version of the input file we want
			array(string) in=glob(prefix+" *.wav",dir); string infn;
			if (!sizeof(in))
			{
				string fn;
				if (parts[0]=="999") {fn=tweaked_soundtrack; infn=prefix+" movie sound track.wav";}
				else
				{
					fn=glob(parts[0]+"*.mp3",ostmp3dir)[0]; //If it doesn't exist, bomb with a tidy exception.
					infn=prefix+fn[3..<3]+"wav";
					fn=ost_mp3+"/"+fn;
				}
				write("Creating %s from MP3\n",infn);
				array(string) args=({"avconv","-i",fn});
				if (partial_start) args+=({"-ss",partial_start});
				if (partial_len) args+=({"-t",partial_len});
				exec(args+({infn}));
				dir=get_dir(); if (!has_value(dir,infn)) exit(1,"Was not able to create %s - exiting\n",infn);
			}
			else infn=in[0];

			write("%s %s: %s - %O\n",prevtracks[i]==""?"Creating":"Rebuilding",outfn,start,infn);
			//eg: sox 111* 01.wav delay 0:00:05 0:00:05
			array(string) args=({"sox",infn,outfn});
			if (temposhift)
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
				float tempo=(float)temposhift;
				if (tempo>.998 && tempo<1.002) args+=({"tempo","-l",temposhift});
				else args+=({"tempo","-m",temposhift});
			}
			if (fade) args+=({"fade"})+fade/"/";
			exec(args+({"delay",start,start}));
			changed=1;
		}
		//TODO: Use `sox --i -D outfn` for better precision
		sscanf(Process.run(({"sox","--i",outfn}))->stdout,"%*sDuration       : %d:%d:%d.%s ",int hr,int min,int sec,string ms);
		int endpos=hr*3600000+min*60000+sec*1000+(int)(ms+"000")[..2];
		if (!nonwordsmode && !nonmessmode) //Tracks tagged [Instrumental] exist only as alternates for corresponding [Words] tracks. Don't update lastpos, don't create subtitles records.
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
			string desc=parts[0];
			array(string) mp3=glob(parts[0]+"*.mp3",ostmp3dir); if (sizeof(mp3)) sscanf(mp3[0],"%*s - %s.mp3",desc);
			if (parts[0]=="999") desc="Shine-through";
			srt->write("%d\n%s --> %s\n%[1]s - %[2]s\n%02d: %s\n\n",++srtcnt,srttime(startpos),srttime(endpos),i,desc);
		}
		if (ignoreto && ignoreto<startpos) continue; //Can't have any effect on the resulting sound, so elide it
		if (endpos<ignorefrom) continue;
		foreach (trackdefs;int i;string t)
		{
			if (has_value(t,'w') ? nonwordsmode : wordsmode) continue;
			if (has_value(t,'m') ? nonmessmode : messmode) continue;
			if (!has_value(t,'9') && parts[0]=="999") continue;
			tracklist[i]+=({outfn});
		}
	}
	write("Total gap: %s\nTotal abutting tracks: %d\nTotal overlap: %s\nFinal position: %s\nNote that these figures may apply to only the beginning of the movie.\n",mstime(gap),abuttals,mstime(overlap),mstime(lastpos));
	if (changed) rm(glob(sprintf(combined_soundtrack,"*"),get_dir())[*]);
	array(string) inputs=({"-i",movie}),map=({"-map","0:v"});
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
				moreargs+=({"remix","0","-v.05"});
			}
			if (has_value(t,'r'))
			{
				if (!file_stat(right_soundtrack))
				{
					write("Rebuilding %s (muting channel from %s)\n",right_soundtrack,tweaked_soundtrack);
					exec(({"sox","-S",tweaked_soundtrack,right_soundtrack,"remix","0","-"}));
				}
				parts=({sprintf(combined_soundtrack,t+"!"),right_soundtrack});
				moreargs+=({"remix","-v.05","0"});
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
	rm(outputfile);
	if (!ignorefrom && !ignoreto)
	{
		//The surtitles can cause ugly endings in partial builds, so it's tidier
		//to just suppress them. You could choose to reenable them if you like.
		map+=({"-map",(sizeof(inputs)/2)+":s"});
		inputs+=({"-i",trackidentifiers});
	}
	exec(({"avconv"})+inputs+map+times+({"-c:v","copy","-c:s","copy",outputfile}));
	Stdio.write_file("prevtracks",encode_value(tracks-({""})));
	write("Total time: %.2fs\n",time(start));
}
