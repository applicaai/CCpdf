#!/bin/bash

sources="$1"

out_dir="downloaded"
mkdir -p $out_dir

if [[ "$sources" == "" ]]
then
    cat >&2 <<'END_OF_HELP'
Downloading PDFs of the ccpdf corpus from a number of publicly available sources:

   bash download-from-crawl.sh source1 source2 ... < pdf-list.txt

where each source is one of: cc web archive.org
   e.g.:

   bash download-from-crawl.sh cc web archive.org < pdf-list.txt

Possible sources:
  - cc - extracts PDF files directly from Common Crawl dumps, unfortunately
         only shorter PDFs (< 1MBs) can be downloaded this way (larger PDFs
         would be truncated)
  - web - downloads PDF files from the original URLs, uses aria2c underneath,
          so the download is parallelized and pretty fast
  - archive.org - downloads PDF files from archive.org

The order of sources matters (they are run from left to right). A source can be repeated,
it will be run twice then (might make some sense for the 'web' method in case of transitory
problems).

The script checks whether a downloaded file is a valid PDF file (using `file` and `pdfinfo`
commands).
END_OF_HELP
fi

inp_method=cat

inp_copy=input_copy.txt
inp_filtered=input_filtered.txt

size_limit=1000000

process()
{
    tee $inp_copy | grep -E -v '^id\s'
}

download_from_cc()
{
    $inp_method | process | while IFS=$'\t' read -r id domain url stamp size offset warc ; do
        if [[ $size -le $size_limit ]]
        then
            echo >&2 "Getting '$url'"

            cc_url=https://data.commoncrawl.org/$warc

            echo >&2 "From '$cc_url'"

            curl -s -r${offset}-$((${offset}+${size}-1)) ${cc_url} --output ${id}.pdf.gz

            zcat ${id}.pdf.gz | perl -ne 'print if /^%PDF/..1' > $out_dir/${id}.pdf
            rm ${id}.pdf.gz
        fi
    done
}

download_from_web()
{
    aria_script="aria.lst"
    rm -rf $aria_script

    $inp_method | process | while IFS=$'\t' read -r id domain url stamp size offset warc ; do
        echo "$url" >> $aria_script
        echo "  out=$out_dir/${id}.pdf" >> $aria_script
    done

    aria2c -j 10 --check-certificate=false -i $aria_script -m 1
}

download_from_archive_org()
{
    $inp_method | process | while IFS=$'\t' read -r id domain url stamp size offset warc ; do
        timestamp=$(curl -s -o - "https://web.archive.org/cdx/search/cdx?url=$url&output=txt" | head -n 1 | cut -d ' ' -f 2)
        if [[ "$timestamp" == "" ]]
        then
            echo >&2 "$url NOT FOUND"
        else
            archive_org_url="https://web.archive.org/web/$timestamp/$url"
            echo >&2 "FOUND: $archive_org_url"
            curl -s -o $out_dir/${id}.pdf "$archive_org_url"
        fi
    done
}

check_pdf()
{
    pdf_file_path="$1"
    if [[ -r $pdf_file_path ]]
    then
        mime_filetype=$(file -b $pdf_file_path)
        if [[ $mime_filetype == PDF* ]]
        then
            if pdfinfo $pdf_file_path > /dev/null 2> /dev/null;
            then
                return 0
            else
                rm $pdf_file_path
                return 1
            fi
        else
            rm $pdf_file_path
            return 1
        fi
    else
        return 1
    fi
}

check_downloaded()
{
    rm -f $inp_filtered
    touch $inp_filtered
    cat $inp_copy | while IFS=$'\t' read -r id domain url stamp size offset warc ; do
        if check_pdf $out_dir/${id}.pdf;
        then
            :
        else
            echo -e "$id\t$domain\t$url\t$stamp\t$size\t$offset\t$warc" >> $inp_filtered
        fi
    done
}

check_requirement()
{
    req="$1"
    package="$2"

    if ! command -v $req
    then
        echo >&2 "No $req installed"
	if [[ "$package" != "" ]]
	then
	    echo >&2 "   ($package package)"
	fi
        exit 1
    fi
}

check_requirements()
{
    check_requirement aria2c aria2
    check_requirement curl
    check_requirement file
    check_requirement pdfinfo poppler-utils
}

check_requirements

for source in $@
do
    echo >&2 "========================================="
    echo >&2 "Running source $source"

    if [[ "$source" == "cc" ]]
    then
        download_from_cc
    elif [[ "$source" == "web" ]]
    then
        download_from_web
    elif [[ "$source" == "archive.org" ]]
    then
        download_from_archive_org
    else
        echo >&2 "Unknown source $source"
        exit 1
    fi

    check_downloaded
    inp_method="cat $inp_filtered"
done
