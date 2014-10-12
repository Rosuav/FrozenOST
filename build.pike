#!/usr/local/bin/pike

//Source file locations
constant movie="Frozen 2013 720p HDRIP x264 AC3 TiTAN.mkv"; //or from /video/Disney/
constant ost_mp3="../Downloads/Various.Artists-Frozen.OST-2013.320kbps-FF"; //Directory of MP3 files

//Intermediate file names
constant orig_soundtrack="MovieSoundTrack.wav";
constant tweaked_soundtrack="MovieSoundTrack_bitratefixed.wav";
constant combined_soundtrack="soundtrack.wav";

constant outputfile="Frozen plus OST.mkv";

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
	array tracks=Stdio.read_file("tracks")/"\n"; //Lines of text
	tracks=array_sscanf(tracks[*],"%[0-9] %[0-9:.]"); //Parsed: ({file prefix, start time})
	tracks=tracks[*]*" "-({""}); //Recombined: "prefix start"
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
	for (int i=0;i<tottracks;++i)
	{
		string outfn=sprintf("%02d.wav",i);
		if (tracks[i]==prevtracks[i] && has_value(dir,outfn)) continue; //Unchanged and file exists.
		rm(outfn);
		if (tracks[i]=="") {write("Removing %s\n",outfn); continue;} //Track list shortened - remove the last N tracks.
		[string prefix,string start]=tracks[i]/" ";

		//Find and maybe create the .wav version of the input file we want
		array(string) in=glob(prefix+"*.wav",dir); string infn;
		if (!sizeof(in))
		{
			if (!ostmp3dir) ostmp3dir=get_dir(ost_mp3); //Cache on first load - it shouldn't change
			string fn=glob(prefix+"*.mp3",ostmp3dir)[0]; //If it doesn't exist, bomb with a tidy exception.
			infn=fn-".mp3"+".wav";
			write("Creating %s from MP3\n",infn);
			exec(({"avconv","-i",ost_mp3+"/"+fn,infn}));
			dir=get_dir(); if (!has_value(dir,infn)) exit(1,"Was not able to create %s - exiting\n",infn);
		}
		else infn=in[0];

		write("%s %s: %s - %O\n",prevtracks[i]==""?"Creating":"Rebuilding",outfn,start,infn);
		//eg: sox 111* 01.wav delay 0:00:05 0:00:05
		exec(({"sox",infn,outfn,"delay",start,start}));
	}
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
	//Note that the original (tweaked) sound track is incorporated, for reference.
	//Remove that parameter when it's no longer needed - or keep it, as a feature.
	write("Rebuilding %s\n",combined_soundtrack);
	int t=time();
	//Begin code cribbed from Process.run()
	Stdio.File mystderr = Stdio.File();
	object p=Process.create_process(({"sox","-S","-m","-v",".5","??.wav",tweaked_soundtrack,combined_soundtrack}),(["stderr":mystderr->pipe()]));
	Pike.SmallBackend backend = Pike.SmallBackend();
	mystderr->set_backend(backend);
	mystderr->set_read_callback(lambda( mixed i, string data) {write(replace(data,"\n","\r"));}); //Write everything on one line, thus disposing of the unwanted spam :)
	mystderr->set_close_callback(lambda () {mystderr = 0;});
	while (mystderr) backend(1.0);
	p->wait();
	//End code from Process.run()
	write("\n-- done in %.2fs\n",time(t));
	rm(outputfile);
	array(string) times=({ });
	if (sscanf(Stdio.read_file("partialbuild")||"","%[0-9:] %[0-9:]",string start,string len) && start && start!="")
		times=({"-ss",start,"-t",len||"0:01:00"});
	exec(({"avconv","-i",movie,"-i",combined_soundtrack,"-map","0:v","-map","1:a:0","-map","0:a:0"})+times+({"-c:v","copy",outputfile}));
	Stdio.write_file("prevtracks",encode_value(tracks-({""})));
	write("Total time: %.2fs\n",time(start));
}
