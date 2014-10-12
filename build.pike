#!/usr/local/bin/pike

int main()
{
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
	array(string) dir=get_dir();
	for (int i=0;i<tottracks;++i)
	{
		string outfn=sprintf("%02d.wav",i);
		if (tracks[i]==prevtracks[i] && has_value(dir,outfn)) continue; //Unchanged and file exists.
		rm(outfn);
		if (tracks[i]=="") {write("Removing %s\n",outfn); continue;} //Track list shortened - remove the last N tracks.
		[string prefix,string start]=tracks[i]/" ";
		string infn=filter(dir,has_prefix,prefix)[0];
		write("%s %s: %s - %O\n",prevtracks[i]==""?"Creating":"Rebuilding",outfn,start,infn);
		//eg: sox 111* 01.wav delay 0:00:05 0:00:05
		Process.create_process(({"sox",infn,outfn,"delay",start,start}))->wait();
	}
	//Two hacks:
	//1) Incorporate the original sound track, for reference. Just remove that parameter when done.
	//2) Cut short the avconving after creating a short file - the -t and its next arg. Again, just remove it when done.
	write("Rebuilding soundtrack.wav\n");
	Process.create_process(({"sox","-m","-v","1","??.wav","MovieSoundTrack_tweaked.wav","soundtrack.wav"}))->wait(); //Note that sox will (unusually) do its own globbing, so we don't have to
	rm("Frozen plus OST.mkv");
	Process.create_process(({"avconv","-i","Frozen 2013 720p HDRIP x264 AC3 TiTAN.mkv","-i","soundtrack.wav","-map","0:v","-map","1:a:0","-map","0:a:0","-t","0:03:30","-c:v","copy","Frozen plus OST.mkv"}))->wait();
	Stdio.write_file("prevtracks",encode_value(tracks));
}
