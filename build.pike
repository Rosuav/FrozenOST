#!/usr/local/bin/pike

//Source file locations
constant movie="Frozen original movie.mkv";
constant moviesource="/video/Disney/Frozen 2013 720p HDRIP x264 AC3 TiTAN.mkv"; //Must already exist; it'll be copied local for speed (and to allow *.mkv to be deleted safely). This directory can be mounted from a remote system.
constant ost_mp3="../Downloads/Various.Artists-Frozen.OST-2013.320kbps-FF"; //Directory of MP3 files

//Intermediate file names
constant orig_soundtrack="MovieSoundTrack.wav"; //Direct rip from movie above
constant tweaked_soundtrack="MovieSoundTrack_bitratefixed.wav"; //orig_soundtrack converted down to 2 channels and 44KHz
constant combined_soundtrack="soundtrack_%s.wav"; //All the individual track files (gets the mode string inserted)

constant outputfile="Frozen plus OST.mkv"; //The video from movie, the audio from all combined_soundtrack files, and the audio from movie.
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
]);
constant modes=([
	"": ({"9", "w9", "c"}), //Default build
	"mini": ({"9", "w9"}), "imini": ({"9"}), "wmini": ({"w9"}), //Quicker build, much quicker if you take only one track
	"sync": ({"9s", "ws9"}), "isync": ({"s9"}), "wsync": ({"ws9"}), //Include sync track
	"full": ({ }), //Everything we can think of! Provided elsewhere as neither sort() nor Array.array_sort() can be used in a constant definition.
]);

//Convert a floating-point time position into .srt format: HH:MM:SS,mmm (comma between seconds and milliseconds)
string srttime(float tm)
{
	int t=(int)tm;
	return sprintf("%02d:%02d:%02d,%03d",t/3600,(t/60)%60,t%60,(int)((tm-t)*1000));
}

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
	}
	if (argc>1 && modes[argv[1]]) mode=argv[1]; //Override mode from command line if possible; ignore unrecognized args.
	array tracks=Stdio.read_file("tracks")/"\n"; //Lines of text
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
		write("Copying %s from %s\n",movie,moviesource);
		Stdio.cp(moviesource,movie);
	}
	if (!file_stat(tweaked_soundtrack))
	{
		if (!file_stat(orig_soundtrack))
		{
			write("Rebuilding %s (ripping from %s)\n",orig_soundtrack,movie);
			exec(({"avconv","-i",movie,orig_soundtrack}));
		}
		write("Rebuilding %s (fixing bitrate and channels from %s)\n",tweaked_soundtrack,orig_soundtrack);
		//Downmix from 5.1 to stereo: http://forum.doom9.org/archive/index.php/t-152034.html
		exec(({"sox","-S",orig_soundtrack,"-r","44100",tweaked_soundtrack,"remix","-m","1v0.3254,3v0.2301,5v0.2818,6v0.1627","2v0.3254,3v0.2301,5v-0.1627,6v-0.2818"}));
	}
	//Figure out the changes between the two versions
	//Note that this copes poorly with insertions/deletions/moves, and will
	//see a large number of changed tracks, and simply recreate them all.
	array(string) dir=get_dir(),ostmp3dir=get_dir(ost_mp3);
	int changed;
	array(array(string)) tracklist=allocate(sizeof(trackdefs),({ }));
	float lastpos=0.0;
	float overlap=0.0,gap=0.0; int abuttals;
	Stdio.File srt=Stdio.File(trackidentifiers,"wct");
	int srtcnt=0;
	for (int i=0;i<tottracks;++i)
	{
		string outfn=sprintf("%02d.wav",i);
		array parts=tracks[i]/" "; if (sizeof(parts)==1) parts+=({""});
		if (parts[1]=="::") {verbose("%s: placing at %s\n",outfn,parts[1]=(string)lastpos); tracks[i]=parts*" ";} //Explicit abuttal - patch in the actual time, for the use of prevtracks
		string prefix=parts[0],start=parts[1];
		int startpos; foreach (start/":",string part) startpos=(startpos*60)+(int)part; //Figure out where this track starts - will round down to 1s resolution
		float pos=(float)startpos; if (has_value(start,'.')) pos+=(float)("."+(start/".")[-1]); //Patch in the decimal :)
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
					float npos=(float)nextpos; if (has_value(next,'.')) npos+=(float)("."+(next/".")[-1]);
					tag="L"+(npos-pos);
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
			if (temposhift) args+=({"tempo","-m",temposhift});
			if (fade) args+=({"fade"})+fade/"/";
			exec(args+({"delay",start,start}));
			changed=1;
		}
		sscanf(Process.run(({"sox","--i",outfn}))->stdout,"%*sDuration       : %d:%d:%f",int hr,int min,float sec);
		float endpos=hr*3600+min*60+sec;
		if (!nonwordsmode && !nonmessmode) //Tracks tagged [Instrumental] exist only as alternates for corresponding [Words] tracks. Don't update lastpos, don't create subtitles records.
		{
			if (pos>lastpos)
			{
				verbose("%s: gap %.2f -> %.2f\n",outfn,pos-lastpos,gap+=pos-lastpos);
				//TODO: Auto-shine-through??
				srt->write("%d\n%s --> %s\n%[1]s - %[2]s\n(%f seconds)\n\n",++srtcnt,srttime(lastpos),srttime(pos),pos-lastpos);
				lastpos=pos;
			}
			else if (pos==lastpos) verbose("%s: abut (#%d)\n",outfn,++abuttals);
			else verbose("%s: overlap %.2f -> %.2f\n",outfn,lastpos-pos,overlap+=lastpos-pos);
			lastpos=endpos;
			string desc=parts[0];
			array(string) mp3=glob(parts[0]+"*.mp3",ostmp3dir); if (sizeof(mp3)) sscanf(mp3[0],"%*s - %s.mp3",desc);
			if (parts[0]=="999") desc="Shine-through";
			srt->write("%d\n%s --> %s\n%[1]s - %[2]s\n%[0]d: %s\n\n",++srtcnt,srttime(pos),srttime(endpos),desc);
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
	write("Total gap: %.2f\nTotal abutting tracks: %d\nTotal overlap: %.2f\nFinal position: %.2f\nNote that these figures may apply to only the beginning of the movie.\n",gap,abuttals,overlap,lastpos);
	if (changed) rm(glob(sprintf(combined_soundtrack,"*"),get_dir())[*]);
	array(string) inputs=({"-i",movie}),map=({"-map","0:v"});
	foreach (trackdefs;int i;string t)
	{
		if (t=="c") {map+=({"-map","0:a:0","-c:a:"+(sizeof(inputs)/2-1),"copy"}); continue;} //Easy. No input, just another thing to map in.
		if (has_value(t,'s')) tracklist[i]+=({tweaked_soundtrack});
		string soundtrack=sprintf(combined_soundtrack,t);
		if (!file_stat(soundtrack))
		{
			write("Rebuilding %s from %d parts\n",soundtrack,sizeof(tracklist[i]));
			int t=time();
			array trim=ignoreto?({"trim","0",(string)ignoreto}):({ }); //If we're doing a partial build, cut it off at the ignore position to save processing.
			Process.run(({"sox","-S","-m","-v",".5"})+tracklist[i]/1*({"-v",".5"})+({soundtrack})+trim,
				(["stderr":lambda(string data) {write(replace(data,"\n","\r"));}]) //Write everything on one line, thus disposing of the unwanted spam :)
			);
			write("\n-- done in %.2fs\n",time(t));
		}
		int id=sizeof(inputs)/2; //Count the inputs prior to adding this one in - map identifiers are zero-based.
		map+=({"-map",id+":a:0","-metadata:s:a:"+(id-1),"title="+(trackdesc[t]||"Soundtrack: "+t)});
		inputs+=({"-i",soundtrack});
	}
	rm(outputfile);
	map+=({"-map",(sizeof(inputs)/2)+":s"});
	inputs+=({"-i",trackidentifiers});
	exec(({"avconv"})+inputs+map+times+({"-c:v","copy","-c:s","copy",outputfile}));
	Stdio.write_file("prevtracks",encode_value(tracks-({""})));
	write("Total time: %.2fs\n",time(start));
}
