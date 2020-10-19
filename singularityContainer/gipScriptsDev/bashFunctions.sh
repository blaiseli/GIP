function bwaMapSample {
    #The function maps the reads, realign to homogenize the indels and mark duplicates
    #implementing http://www.htslib.org/workflow/#mapping_to_variant
    ########
    #INPUTS#
    ########
    #S is the sample name (mates will be created by adding "_X.fastq.gz")
    #ASSEMBLY is the genome assembly (multi fasta file with chromosomes)
    #C is the number of CPUs
    #INDEX is the folder holding the BWA indexes
    #O out dir
    #delDup [true|false] whether to delete marked duplicates
    #P1/P2. Specify the name of the two FASTQ faile pairs. Recommended as the FASTQ paired files can have weird names.
    local S=$1;
    local ASSEMBLY=$2;
    local C=$3;
    local INDEX=$4;
    local O=$5;
    local delDup=$6;
    local P1=$7;
    local P2=$8;
    echo "##PROG $S";
    echo "##PROG map";
    if [ -z $P2 ]; then
        bwa mem -R "@RG\tID:${S}\tSM:${S}" -M -t $C ${INDEX}/db $P1 > ${O}/${S}.sam;
    else
        bwa mem -R "@RG\tID:${S}\tSM:${S}" -M -t $C ${INDEX}/db $P1 $P2 > ${O}/${S}.sam;
    fi;
    echo "##PROG fixmate";
    samtools fixmate -O bam ${O}/${S}.sam ${O}/${S}_fixmate.bam;
    echo "##PROG sort";
    samtools sort -O bam -o ${O}/${S}.bam -T ${O}/__tmpGio${S}__ ${O}/${S}_fixmate.bam;
    samtools index ${O}/${S}.bam;
    echo "##PROG RealignerTargetCreator";
    java -Xmx2g -jar /bin/GenomeAnalysisTK.jar -T RealignerTargetCreator -R $ASSEMBLY -I ${O}/${S}.bam -o ${O}/${S}.intervals;
    echo "##PROG IndelRealigner";
    java -Xmx4g -jar /bin/GenomeAnalysisTK.jar -T IndelRealigner -R $ASSEMBLY -I ${O}/${S}.bam -targetIntervals ${O}/${S}.intervals -o ${O}/${S}_realigned.bam;
    echo "##PROG Markduplicated";
    java -jar /bin/picard.jar MarkDuplicates INPUT=${O}/${S}_realigned.bam OUTPUT=${O}/${S}_realignedMarkDup.bam VALIDATION_STRINGENCY=LENIENT M=${O}/${S}.MarkDup.log TMP_DIR=${O}/${S}_MarkDuplicatesTMPDIR REMOVE_DUPLICATES=${delDup};
    rm -rf ${O}/${S}.sam ${O}/${S}_fixmate.bam ${O}/${S}.intervals ${O}/${S}.bam ${O}/${S}.bam.bai ${O}/${S}_realigned.bam ${O}/${S}_realigned.bai ${O}/${S}_MarkDuplicatesTMPDIR;
    mv ${O}/${S}_realignedMarkDup.bam ${O}/${S}.bam;
    samtools index ${O}/${S}.bam    
}
function pcMapqPerNt {
#OUTPUT:
    #for each base, compute the percent of reads with MAPQ >= of the specified value
#INPUT:
    #BAM=bam file
    #MAPQ=desired MAPQ threshold
    #OUT=outName
    local BAM=$1
    local MAPQ=$2
    local OUT=$3
    samtools view -q $MAPQ -o ${OUT}_tmpMapqPerNtFiltered.bam $BAM
    samtools depth ${OUT}_tmpMapqPerNtFiltered.bam $BAM -aa | awk '{if($4 == 0){r=0}else{r=($3/$4)*100} printf $1 "\t" $2 "\t" ; printf"%.0f\n",r  }'> ${OUT}
    gzip $OUT
    rm -rf ${OUT}_tmpMapqPerNtFiltered.bam
}
function mapqPerNt {
    #compute mean read MAPQ mapping score for each base
    #very slow. Consider using pcMapqPerNt
    #######
    #INPUT#
    #######
    #BAM: bam file
    #CHRSIZE: chromosome sizes file
    #OUT: output file name (including directory path)
    ########
    #OUTPUT#
    ########
    #.covPerNt file
    local BAM=$1
    local CHRSIZE=$2
    local OUT=$3
    rm -rf $OUT
    cat $CHRSIZE | while IFS='' read -r line || [[ -n "$line" ]]; do
        local CHR=`echo $line |awk '{print $1}'`
        local SIZE=$(echo $line |awk '{print $2}')
	for ((pos=1;pos<=$SIZE;pos++)); do 
		samtools view $BAM ${CHR}:${pos}-$pos | awk '{sum+=$5} END {if(sum > 0){avg = sprintf("%.0f" , sum/NR); print '$CHR' "\t" '$pos' "\t" avg  }else{print 0}}' >> $OUT
    	done
    done
    gzip $OUT
}

function covPerNt {
    #very very similar to computCov function, but better written
    #this function runs bedtools genomecov and normalizes (option) each nucleotide coverage by the median genomic coverage
    #######
    #INPUT#
    #######
    #BAM: bam file
    #CHRSIZE: chromosome sizes file
    #OUT: output file name (including directory path)
    #MODE: normalization strategy ["MEDIAN"|"NOTNORMALIZED"]
    #MAPQ: min read MAPQ
    ########
    #OUTPUT#
    ########
    #.covPerNt file
    #.medianGenomeCoverage file
    local BAM=$1
    local CHRSIZE=$2
    local OUT=$3
    local MODE=$4
    local MAPQ=$5
    samtools view -b -q $MAPQ $BAM | bedtools genomecov -ibam stdin -g $CHRSIZE -d -split > ${OUT}_notNormalized_
    if [ $MODE == "MEDIAN" ]; then
        #the normalization by median coverage works very well. Unless there is an aneuploidy, the expected value is 1 for each nucleotide.
        mkdir -p ${OUT}_notNormalized_TMPsortDir
	local MEDIANCOV=`cut -f3 ${OUT}_notNormalized_ | sort -n -T ${OUT}_notNormalized_TMPsortDir |  awk ' { a[i++]=$1; } END { x=int((i+1)/2); if (x < (i+1)/2) print (a[x-1]+a[x])/2; else print a[x-1]; }'`
        awk '{printf $1 "\t" $2 "\t"; printf "%.2f\n",$3/'$MEDIANCOV' }' ${OUT}_notNormalized_ > $OUT
	rm -rf ${OUT}_notNormalized_  ${OUT}_notNormalized_TMPsortDir
        echo $MEDIANCOV > ${OUT}.medianGenomeCoverage
    elif [ $MODE == "NOTNORMALIZED" ]; then
        mv ${OUT}_notNormalized_ $OUT
    else
        rm ${OUT}_notNormalized_
        echo "$MODE not recognized";
    fi
}

function addMapqToCovPerGe {
	#######
	#INPUT#
	#######
	#BAM: the bam file used to generate the covPerGe file
	#GENCOV: gene coverage file (.covPerGe) with syntax "gene_id locus meanCoverage normalizedMeanCoverage" generated by covPerGe
	#MODE: compute "MEDIAN" or "MEAN" gene MAPQ
	########
        #OUTPUT#
        ########
	#it returns the input .covPerGe with an extra column storing the median MAPQ scores 
	local BAM=$1
        local GENCOV=$2
        local MODE=$3
	echo "MAPQ" > ${GENCOV}_tmpAvgMapq
        tail -n +2 $GENCOV | while IFS='' read -r line || [[ -n "$line" ]]; do
                local REGION=`echo $line |awk '{print $2}'`;
                ##for debugging
                #echo $REGION | tr "\n" "\t";
        	if [ $MODE == "MEDIAN" ]; then        
			samtools view $BAM $REGION | awk ' { a[i++]=$5; } END { x=int((i+1)/2); if (x < (i+1)/2) print (a[x-1]+a[x])/2; else print a[x-1]; }'; 
        	elif [ $MODE == "MEAN" ]; then 
			samtools view $BAM $REGION | awk '{total+=$5}END{if(total > 0 ){print total/NR}else{print 0} }';
		else
			echo "$MODE not recognized";
		fi
	done >> ${GENCOV}_tmpAvgMapq
        paste  $GENCOV ${GENCOV}_tmpAvgMapq > ${GENCOV}_tmpAvgMapq2
        mv ${GENCOV}_tmpAvgMapq2 $GENCOV
        rm ${GENCOV}_tmpAvgMapq
}


function covPerGe {
    ########
    #OUTPUT#
    ########
    #.covPerGe file. This format includes both the gene mean coverage and the gene mean coverage normalized by the chromosome median coverage. To estimate the mean coverage the N bases are not considered. 
    #NOTE: genes not on the chromosomes of the chrCoverageMedians file are removed from the output 
    #covPerGe fields:
        #gene_id: gene identifier
        #locus: gene chr:start-end      
        #meanCoverage: Mean nucleotide sequencing coverage of the bases belonging to the gene (N bases aren't counted)   
        #normalizedMeanCoverage: #meanCoverage (N bases aren't counted) / chromosome median coverage     
        #MAPQ: average MAPQ of the reads mapping to the gene
    
    ##WARNING: You can have genes coverage, but still with a MAPQ >0 becaue you can have very few reads mapping in the gene (with a certain MAPQ). Similarly, you can have genes with 0 coverage and 0 MAPQ (so no mapping reads at all)

    #######
    #INPUT#
    #######
    #BAM: A genomic-sequencing BAM
    #OUT: covPerGe output name
    #GENES: A gene gtf annotation file
    #CHRM: chromosome median coverage file (chrCoverageMedians file, syntax: chrXX median .* )
    #MAPQ: reads below thi threshold won't contribute to the sequencing depth, but they will still be counted for the gene average MAPQ
    #covPerGeMAPQoperation: compute MEDIAN or MEAN MAPQ of the reads mapping to the gene 
    #ASSEMBLY: genome assembly multifasta file
    local BAM=$1
    local OUT=$2
    local GENES=$3
    local CHRM=$4 
    local MAPQ=$5
    local covPerGeMAPQoperation=$6
    local ASSEMBLY=$7
    
    perl -e '
        open(C,"<'$CHRM'");
        while(<C>){
                if($_=~/^(\S+)\s+(\S+)/){$chr=$1;$m=$2; $mCovs{$chr} = $m;}
        }
        close C;
        
        open(F,"<'$GENES'");
        open(O,">'$OUT'");
        print O "gene_id\tlocus\tmeanCoverage\tnormalizedMeanCoverage\n";
        while(<F>){
            open(TMP,">'$OUT'_currentGene.bed");
            if($_=~/gene_id \"([^\"]+)\"/){$ge=$1;}
            if($_=~/^(\S+)\s+\S+\s+\S+\s+(\S+)\s+(\S+)/){$chr=$1;$st=$2;$en=$3;}
            if(! defined $mCovs{$chr}){close(TMP); next;}

            #subtract from the gene length the number of Ns
            $cmd1="'samtools' faidx '$ASSEMBLY' ${chr}:${st}-${en}  | tail -n +2  | awk \x27{print toupper(\$0)}\x27 | tr -cd  N | wc -c | tr -d \x27\\n\x27";
            $Ns=`$cmd1`; 
            die ("covPerGe faidx did not work for command\n$cmd1\n$!") if ($?);
            my $realLength = ($en - $st) - $Ns;

	    print O "$ge\t${chr}:${st}-${en}\t";
            print TMP "${chr}\t${st}\t${en}\n";
            $cmd2="'samtools'" . " view -b -q " . "'$MAPQ'" . "'$BAM'" . " ${chr}:${st}-${en} | " . "'bedtools'" . " coverage -a " . "'$OUT'" . "_currentGene.bed -b stdin -d -split | awk  \x27{x+=\$5;next}END{print x/$realLength}\x27"  ;
            $meanGeneCov=`$cmd2`; if($?){die "error with $cmd2\n";}
            chomp $meanGeneCov;
            $normalizedMeanGeneCov = $meanGeneCov / $mCovs{$chr};
            print O "$meanGeneCov\t$normalizedMeanGeneCov\n";
            close(TMP);
        }
        close O;
        close F; '
    rm -rf ${OUT}_currentGene.bed ${OUT}_tmpCovPerGe_res ${OUT}_tmpCovPerGe

    addMapqToCovPerGe $BAM $OUT $covPerGeMAPQoperation 
    gzip $OUT
}

function chrMedianCoverages {
#INPUT
#S: bam file name (without .bam extention)
#CHRSIZE: reference genome chromosome sizes (list of: chrXX size)
#MAPQ: Min read MAPQ (recommended 5)
#CHRS: array of chr names. E.g. CHRS=(1 2 3 4) chromosomes not included in the list will be skipped
#D: Directory with containing the bam files
#GAPS: gzipped gaps in bed format

#OUTPUT
#chrCoverageMedians_ File with chromosome name, median nucleotide coverage, and +/- 2 MADs
    local S=$1
    local CHRSIZE=$2
    local MAPQ=$3
    CHRS=$4
    local D=$5
    local GAPS=$6

    echo -e "CHR\tMEDIANCOV\tMEDIANCOVminus2MAD\tMEDIANCOVplus2MAD" > ${D}/chrCoverageMedians_$S
    cat $CHRSIZE | while IFS='' read -r line || [[ -n "$line" ]]; do
        local CHR=`echo $line |awk '{print $1}'`
        local END=$(echo $line |awk '{print $2}')
        local CHECK=`case "${CHRS[@]}" in  *"$CHR"*) echo "found" ;; esac`
        if [ -z "$CHECK" ]; then continue ; fi
        echo -e "$CHR\t1\t$END" > ${D}/chr_${S}.bed
        #estimate the median coverage +/- 2 MADs (median absolute deviation)
        samtools view -b -q $MAPQ ${D}/${S}.bam $CHR |  bedtools coverage -a ${D}/chr_${S}.bed -b stdin -d -split | awk '{print $1 "\t" $4 "\t" $4 "\t" $5 }' > ${D}/_notNormalized_chrCoverageMedians$S
        #remove gaps
        zcat $GAPS > ${D}/TMPgaps$S
      	bedtools intersect -v -a ${D}/_notNormalized_chrCoverageMedians$S -b ${D}/TMPgaps$S > ${D}/_notNormalized_chrCoverageMediansNoGaps$S
        mkdir -p ${D}/TMPsortDir_notNormalized_$S
        local MEDIANCOV=`cut -f4 ${D}/_notNormalized_chrCoverageMediansNoGaps$S | sort -n -T ${D}/TMPsortDir_notNormalized_$S |  awk ' { a[i++]=$1; } END { x=int((i+1)/2); if (x < (i+1)/2) print (a[x-1]+a[x])/2; else print a[x-1]; }'`
        local MAD=`awk 'function abs(x){return ((x < 0.0) ? -x : x)}  {dev=abs($4 - '$MEDIANCOV'); print dev }' ${D}/_notNormalized_chrCoverageMediansNoGaps$S | sort -n -T ${D}/TMPsortDir_notNormalized_$S |  awk ' { a[i++]=$1; } END { x=int((i+1)/2); if (x < (i+1)/2) print (a[x-1]+a[x])/2; else print a[x-1]; }'`
        local maxDp=`perl -e 'print '$MEDIANCOV'+ (2 * '$MAD');'`
	local minDp=`perl -e 'print '$MEDIANCOV'- (2 * '$MAD');'`
	rm -rf ${D}/TMPgaps$S ${D}/_notNormalized_chrCoverageMedians$S ${D}/chr_${S}.bed ${D}/TMPsortDir_notNormalized_$S ${D}/_notNormalized_chrCoverageMediansNoGaps$S
        echo -e "$CHR\t$MEDIANCOV\t$minDp\t$maxDp" >> ${D}/chrCoverageMedians_$S
   done
}

function getSequence {
#OUTPUT: a selected nucleotide sequence (it should work on aminoacid too thought)
#INPUT: multi-fasta file chromosome start end position
#getSequence() does the same as chr_subseq() but without the need of splitting the MFA beforehand
	local MFA=$1
	local CHR=$2
	local START=$3
	local END=$4
	if [ ! -f ${MFA}.fai ]; then
    		samtools faidx $MFA
    	fi 
        samtools faidx $MFA ${CHR}:${START}-${END} | grep -v ">" | tr -d "\n"         
}

function join_by { 
#OUTPUT = joined array
#INPUT= a separator character and an array to join
#http://stackoverflow.com/questions/1527049/join-elements-of-an-array
	local IFS="$1"; 
	shift; echo "$*"; 
}

function filterByCov {
    local IN=$1
    local OUT=$2
    local minNormCovForDUP=$3
    local maxNormCovForDEL=$4
    local SAMPLE_ID=$5
    local DF=$6

    BED=$DF/${IN}.bed
    COV=$DF/coverages/${IN}.cov 
    gunzip ${COV}.gz
    SV=`echo ${OUT: -7} | cut -f1 -d "."`
    echo "#cmd: filterByCov BED is $BED ;;; COV is $COV ;;; SV is $SV" 
    echo -e "locus\tnormCov\tpercReadsSupportingSV\tMAPQ\tSV\tsampleId\tSVid" > $OUT
    perl -e '
    open(F,"<'$COV'") or die "error opening COV\n";
    $_=<F>;
    while(<F>){
        if($_=~/^\S+\s+(\S+)\s+\S+\s+(\S+)\s+(\S+)/){
            $locus   = $1;
            $normCov = sprintf("%.2f",$2);
            $MAPQ    = sprintf("%.2f",$3);
            $h{$locus}{"normCov"} = $normCov;
            $h{$locus}{"MAPQ"}    = $MAPQ;
        }
    }
    close F;
    open(F,"<'$BED'") or die "error opening BED\n";
    while(<F>){
        if($_=~/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/){
            $locus=$1 . ":" . $2 . "-" . $3;
            $h{$locus}{"SVid"} = $4;
            $h{$locus}{"percReadsSupportingSV"} = $5;
        }
    }
    close F;
    foreach $locus (sort { $h{$b}->{"normCov"} <=> $h{$a}->{"normCov"}} keys %h){
        if (! defined $h{$locus}{"normCov"}){"die error in filterByCov\n";};
        $normCov = $h{$locus}{"normCov"};
        $MAPQ    = $h{$locus}{"MAPQ"} ;
        $SVid    = $h{$locus}{"SVid"};
        $percReadsSupportingSV = $h{$locus}{"percReadsSupportingSV"};
        if(('$SV' eq "DUP")&&($normCov < '$minNormCovForDUP')){next;}
        if(('$SV' eq "DEL")&&($normCov > '$maxNormCovForDEL')){next;}
        print "$locus\t$normCov\t$percReadsSupportingSV\t$MAPQ\t'$SV'\t'$SAMPLE_ID'\t$SVid\n";
    }
    ' >> $OUT
}
function ovWithGenes {
    local IN=$1
    local DF=$2
    local FBC=$DF/coverages/${IN}.fbc
    local OUT=$DF/coverages/${IN}.ov
    echo "#cmd: ovWithGenes IN is $IN" 
    tail -n +2 $FBC  | perl -ne 'if($_=~/^([^:]+):([^-]+)-(\S+).*(\S+)\s+\S+$/){$chr=$1; $start=$2; $end=$3; $sample=$4; $locus="${chr}:${start}-${end}"; print "$chr\t$start\t$end\t$locus\n"; }' > ${DF}_tmp.bed
    cat $GENES | perl -ne 'if($_=~/gene_id \"([^\"]+)\"/){$ge=$1;} if($_=~/(\S+)\s+\S+\s+\S+\s+(\S+)\s+(\S+)/){print "$1\t$2\t$3\t$ge\n";}' > ${DF}_genes.bed
    bedtools intersect -loj -a ${DF}_tmp.bed -b ${DF}_genes.bed > ${DF}_tmp.ov
    echo -e "locus\tnormCov\tpercReadsSupportingSV\tMAPQ\tSV\tsampleId\tSVid\tgenes" > $OUT
    perl -e '
    my %h;
    open(F,"<'$DF'_tmp.ov");
    while(<F>){
        if($_=~/^\S+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+\S+\s+(\S+)/){
            my $locus = $1;
            my $ge    = $2;
            push(@{$h{$locus}{'genes'}} , $ge);
        }
    }
    close F;
    open(F,"<'$FBC'");
    $_=<F>;
    while(<F>){
        if($_=~/(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/){
            $locus="$1";
            $h{$locus}{'normCov'}=$2;
            $h{$locus}{'percReadsSupportingSV'}=$3;
            $h{$locus}{'MAPQ'}=$4;
            $h{$locus}{'SV'}=$5;
            $h{$locus}{'sampleId'}=$6;
            $h{$locus}{'SVid'}=$7;
        }
    }
    close F;
    foreach $locus (keys %h){
        my $normCov               = $h{$locus}{'normCov'};
        my $percReadsSupportingSV = $h{$locus}{'percReadsSupportingSV'};
        my $MAPQ                  = $h{$locus}{'MAPQ'};
        my $SV                    = $h{$locus}{'SV'};
        my $sampleId           = $h{$locus}{'sampleId'};
        my $SVid                  = $h{$locus}{'SVid'};
        my $svGenes               = join("," , @{$h{$locus}{'genes'}} );
        $locus=~s/_.*//;
        print "$locus\t$normCov\t$percReadsSupportingSV\t$MAPQ\t$SV\t$sampleId\t$SVid\t$svGenes\n";
    }
    close F;
    ' | sort -k1,1n -k2,2n >> $OUT
    rm  ${DF}_tmp.ov ${DF}_tmp.bed ${DF}_genes.bed
}
function bedForCircos {
    local X=$1
    local OUT=$2

    perl -e '
    open(F,"<'$X'") or die "opening 1 error in bedForCircos\n";
    $_=<F>;
    my $SV;
    while (<F>){
        if($_=~/^(\S+)\s+\S+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+(\S+)/){
            my $locus = $1;
               $SV    = $2;
            my $SVid  = $3;
            push(@{$h{$SVid}},$locus);
        }
    }
    close F;
    open(O,">'$OUT'") or die "cannot write\n";
    if ($SV ne "TRA"){
        foreach $SVid (keys %h){
            my $locus = $h{$SVid}[0];
            my ($chr,$start,$end);
            if($locus=~/([^:]+):([^-]+)-([^-]+)/){
                $chr   = $1;
                $start = $2;
                $end   = $3;
            }
            print O "chr$chr\t$start\t$end\n";
        }
    } else {
        foreach $SVid (keys %h){
            my $locus1 = $h{$SVid}[0];
            my $locus2 = $h{$SVid}[1];
            my ($chr1,$start1,$end1,$chr2,$start2,$end2);
            if($locus1=~/([^:]+):([^-]+)-([^-]+)/){
                $chr1   = $1;
                $start1 = $2;
                $end1   = $3;
            }
            if($locus2=~/([^:]+):([^-]+)-([^-]+)/){
                $chr2   = $1;
                $start2 = $2;
                $end2   = $3;
            }
            print O "chr$chr1\t$start1\t$end1\tchr$chr2\t$start2\t$end2\n";
        }
    }
    close O;
    '
}

function covPerBin_normalizedByChrMedianCov {
########
#OUTPUT#
########
#.covPerBin file normalized by chromosome median coverage    
#######
#INPUT#
#######
#A chromosome median coverage file (chrCoverageMedians file, syntax: chrXX median .* ) and a covPerBin file (syntax: chr start end meanCoverage)
#NOTE1: the input covPerBin file need to be not normalized before this function
#NOTE2: covPerBin input windows that are not on the chromosomes in the chrCoverageMedians file are removed from the output
    local CHRM=$1
    local GCOVBIN=$2
    local OUT=$3
perl -e '
        open(C,"<'$CHRM'");
        while(<C>){
                if($_=~/^(\S+)\s+(\S+)/){$chr=$1;$m=$2; $mCovs{$chr} = $m;}
        }
        close C;

        open(O,">'$OUT'");
        open(F,"<'$GCOVBIN'");
        $header = <F>;
        chomp $header;
        print O "$header\t"."normalizedMeanCoverage\n";
        while(<F>){
                if ($_=~/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/){
                        $chr=$1;
                        $start=$2;
                        $end=$3;
                        $mean=$4;
                        
                        next if(! defined $mCovs{$chr});
                        $normMean   = $mean / $mCovs{$chr};
                        print O "$chr\t$start\t$end\t$mean\t$normMean\n";      
                }
        }
        close F;
        close O;
'
}


function covPerBin {
  local BAM=$1
  local BINSIZE=$2
  local CHRSIZE=$3
  local chrCoverageMedians=$4
  local TMP=$5

  mkdir -p $TMP
  OUT=${BAM/%.bam/.covPerBin}
  BED=${BAM/%.bam/.bed} 
  bedtools bamtobed -split -i $BAM | sort -k1,1 -k2,2n -T $TMP/_sort1 > $BED
  bedtools makewindows -g $CHRSIZE -w $BINSIZE | sort -k1,1 -k2,2n -T $TMP/_sort2 > $TMP/windows
  bedtools map -a $TMP/windows -b $BED -c 5 -o mean -null 0 > $TMP/meanMapq
  bedtools coverage -d -a $TMP/windows -b $BED > $TMP/winCov
  echo -e "chromosome\tstart\tend\tmeanCoverage" > $TMP/covPerBinNotNorm
  awk '{i=$1"\t"1+$2"\t"$3; count[i]++; sum[i]+=$5;} END{ for(i in count) {m = sum[i]/count[i]; print i, m}}  ' $TMP/winCov  | sort -k1,1 -k2,2n >> $TMP/covPerBinNotNorm
  
  covPerBin_normalizedByChrMedianCov2 $chrCoverageMedians $TMP/covPerBinNotNorm $TMP/covPerBin
  perl -e '
  #read mapq
  open(F,"<'$TMP/meanMapq'") or die "covPerBin2 cannot open meanMapq";
  my %h;
  while(<F>){ 
    if ($_=~/^(\S+)\s+(\S+)\s+\S+\s+(\S+)/){
        $h{"${1}_$2"} = $3;
    }
  } 
  close F;
  
  open(O,">'$OUT'") or die "covPerBin2 cannot open out";
  open(F,"<'$TMP/covPerBin'") or die "covPerBin2 cannot open covPerBin";
  $header = <F>;
  chomp $header;
  print O $header . "\tMAPQ\n";
  while(<F>){ 
    if ($_=~/^(\S+)\t(\S+)\t(\S+\t\S+\t\S+)/){
        $chr   = $1;
        $start = $2;
        $a     = $3;
        $s     = $start -1;
        $mapq  = $h{"${chr}_$s"};
        print O "$chr\t$start\t$a\t$mapq\n";

    }
  } 
  close F;
  close O;
  '
  gzip $OUT
  rm -rf $TMP 
}


typeset -fx bwaMapSample 
typeset -fx pcMapqPerNt 
typeset -fx mapqPerNt 
typeset -fx covPerNt  
typeset -fx addMapqToGcovbin 
typeset -fx addMapqToCovPerGe 
typeset -fx normalizedMedianGeneCov 
typeset -fx covPerGe  
typeset -fx blastClust2familyDepth 
typeset -fx getFromTbl 
typeset -fx chrMedianCoverages_v0 
typeset -fx chrMedianCoverages 
typeset -fx getSequence 
typeset -fx join_by  
typeset -fx filterByCov 
typeset -fx ovWithGenes 
typeset -fx bedForCircos 
typeset -fx covPerBin
typeset -fx covPerBin_normalizedByChrMedianCov

