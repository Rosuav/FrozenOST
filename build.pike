#!/usr/local/bin/pike

//Source file locations
constant movie="Frozen 2013 720p HDRIP x264 AC3 TiTAN.mkv";
constant moviepath="/video/Disney/"; //moviepath+movie has to already exist; it'll be copied local for speed (and to allow *.mkv to be deleted safely). This directory can be mounted from a remote system.
constant ost_mp3="../Downloads/Various.Artists-Frozen.OST-2013.320kbps-FF"; //Directory of MP3 files

//Intermediate file names
constant orig_soundtrack="MovieSoundTrack.wav"; //Direct rip from movie above
constant tweaked_soundtrack="MovieSoundTrack_bitratefixed.wav"; //orig_soundtrack converted down to 2 channels and 44KHz
constant combined_soundtrack="soundtrack.wav"; //All the individual track files, but not tweaked_soundtrack
constant full_combined_soundtrack="soundtrack_full.wav"; //All the individual track files *and* tweaked_soundtrack

constant outputfile="Frozen plus OST.mkv"; //The video from movie, the audio from [full_]combined_soundtrack, and the audio from movie.

void exec(array(string) cmd)
{
	int t=time();
	Process.create_process(cmd)->wait();
	float tm=time(t);
	if (tm>5.0) write("-- done in %.2fs\n",tm);
}

int main()
{
	int start=time();
	array(string) times=({ });
	string mode;
	int ignorefrom,ignoreto;
	if (sscanf(Stdio.read_file("partialbuild")||"","%[0-9:] %[0-9:] %[a-z]",string start,string len,mode) && start && start!="")
	{
		times=({"-ss",start,"-t",len||"0:01:00"});
		foreach (start/":",string part) ignorefrom=(ignorefrom*60)+(int)part;
		foreach (len/":",string part) ignoreto=(ignoreto*60)+(int)part; ignoreto+=ignorefrom;
		ignorefrom-=240; //I could measure the length of each track, but it's simpler to just allow four minutes, which is longer than any track I'm working with
	}
	array tracks=Stdio.read_file("tracks")/"\n"; //Lines of text
	tracks=array_sscanf(tracks[*],"%[0-9] %[0-9:.] [%s]"); //Parsed: ({file prefix, start time[, tags]})
	tracks=tracks[*]*" "-({""}); //Recombined: "prefix start[ tags]". The tags are comma-delimited and begin with a key letter.
	array prevtracks;
	catch {prevtracks=decode_value(Stdio.read_file("prevtracks"));};
	if (!prevtracks) prevtracks=({ });
	int tottracks=max(sizeof(tracks),sizeof(prevtracks));
	if (sizeof(tracks)<tottracks) tracks+=({""})*(tottracks-sizeof(tracks));
	if (sizeof(prevtracks)<tottracks) prevtracks+=({""})*(tottracks-sizeof(prevtracks));
	//Figure out the changes between the two versions
	//Note that this copes poorly with insertions/deletions/moves, and will
	//see a large number of changed tracks, and simply recreate them all.
	array(string) dir=get_dir(),ostmp3dir;
	int changed;
	array(string) tracklist=({ });
	for (int i=0;i<tottracks;++i)
	{
		string outfn=sprintf("%02d.wav",i);
		array parts=tracks[i]/" ";
		string prefix=parts[0],start=parts[1];
		int startpos; foreach (start/":",string part) startpos=(startpos*60)+(int)part; //Figure out where this track starts - will round down to 1s resolution
		if (startpos<ignorefrom || (ignoreto && ignoreto<startpos)) continue; //Can't have any effect on the resulting sound, so elide it
		if (tracks[i]==prevtracks[i] && has_value(dir,outfn)) {tracklist+=({outfn}); continue;} //Unchanged and file exists.
		rm(outfn);
		if (tracks[i]=="") {write("Removing %s\n",outfn); continue;} //Track list shortened - remove the last N tracks.
		tracklist+=({outfn});
		string partial_start,partial_len;
		if (parts[0]=="999") {partial_start=parts[1]; prefix+="S"+startpos;}
		if (sizeof(parts)>2) foreach (parts[2]/",",string tag) if (tag!="") switch (tag[0]) //Process the tags, which may alter the prefix
		{
			case 'S': partial_start=tag[1..]; prefix+=tag; break;
			case 'L': partial_len=tag[1..]; prefix+=tag; break;
			default: break;
		}

		//Find and maybe create the .wav version of the input file we want
		array(string) in=glob(prefix+" *.wav",dir); string infn;
		if (!sizeof(in))
		{
			if (!ostmp3dir) ostmp3dir=get_dir(ost_mp3); //Cache on first load - it shouldn't change
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
		exec(({"sox",infn,outfn,"delay",start,start}));
		changed=1;
	}
	if (!file_stat(movie))
	{
		write("Copying %s from %s\n",movie,moviepath);
		Stdio.cp(moviepath+movie,movie);
	}
	if (changed) {rm(combined_soundtrack); rm(full_combined_soundtrack);}
	string soundtrack=combined_soundtrack;
	if (mode=="sync")
	{
		soundtrack=full_combined_soundtrack;
		if (!file_stat(tweaked_soundtrack))
		{
			if (!file_stat(orig_soundtrack))
			{
				write("Rebuilding %s (ripping from %s)\n",orig_soundtrack,movie);
				exec(({"avconv","-i",movie,orig_soundtrack}));
			}
			write("Rebuilding %s (fixing bitrate and channels from %s)\n",tweaked_soundtrack,orig_soundtrack);
			exec(({"sox","-S",orig_soundtrack,"-c","2","-r","44100",tweaked_soundtrack}));
		}
		tracklist+=({tweaked_soundtrack});
	}
	if (!file_stat(soundtrack))
	{
		//Note that the original (tweaked) sound track is incorporated, for reference.
		//Remove that parameter when it's no longer needed - or keep it, as a feature.
		write("Rebuilding %s from %d parts\n",soundtrack,sizeof(tracklist));
		int t=time();
		//Begin code cribbed from Process.run() - this could actually *use* Process.run() if stdout/stderr functions were supported
		Stdio.File mystderr = Stdio.File();
		object p=Process.create_process(({"sox","-S","-m","-v",".5"})+tracklist/1*({"-v",".5"})+({soundtrack}),(["stderr":mystderr->pipe()]));
		Pike.SmallBackend backend = Pike.SmallBackend();
		mystderr->set_backend(backend);
		mystderr->set_read_callback(lambda( mixed i, string data) {write(replace(data,"\n","\r"));}); //Write everything on one line, thus disposing of the unwanted spam :)
		mystderr->set_close_callback(lambda () {mystderr = 0;});
		while (mystderr) backend(1.0);
		p->wait();
		//End code from Process.run()
		write("\n-- done in %.2fs\n",time(t));
	}
	rm(outputfile);
	if (mode!="sync" && mode!="mini") times=({"-map","0:a:0"})+times;
	exec(({"avconv","-i",movie,"-i",soundtrack,"-map","0:v","-map","1:a:0"})+times+({"-c:v","copy",outputfile}));
	Stdio.write_file("prevtracks",encode_value(tracks-({""})));
	write("Total time: %.2fs\n",time(start));
}
