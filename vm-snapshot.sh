#!/bin/bash
#

#####################################################################

# User variables


# Seconds to wait before determining that domain could not be started
STARTWAIT=60

# Seconds to wait before forcibly shutting down domain
STOPWAIT=120

# Do not modify anything below this line

#####################################################################

# Redirect &5 to stdout (for email log)

exec 5>&1

# Setup arguments from command line

BACKUPDEST="$1"
DOMAINS="$2"
MAXBACKUPS="$3"

# Set global variables (do not change)

TOTALSIZE=0
TOTALSECONDS=0

if [ -z "$BACKUPDEST" -o -z "$DOMAINS" ]; then
    echo "Usage: ./vm-snapshot.sh <backup-folder> <list of domains, comma separated, or --all to backup all domains> [max-backups (default is 7 if not specified)]"
    exit 1
fi

if [ -z "$MAXBACKUPS" ]; then
    MAXBACKUPS=7
elif [ $MAXBACKUPS" -ne "$MAXBACKUPS ] 2>/dev/null; then
    echo -e "Error: max-backups must be a number\n\nUsage: ./vm-snapshot.sh <backup-folder> <list of domains, comma separated, or --all to backup all domains> [max-backups (default is 7 if not specified)]"
    exit 1
fi

#
# Function to convert bytes to human readable size
#

human_readable () {
HR_SIZE=$(numfmt --to=iec --suffix=B $1)
}

#
# Main function to backup domain
#

domain_backup () {
	# Start domain backup

	DOMAIN="$1"

	if [[ ! $(virsh list --all --name | grep "${DOMAIN}") == "$DOMAIN" ]] ; then
   	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Failed to find "${DOMAIN}" - exiting"|tee >(cat - >&5))
   	return 1
	fi

	#
	# Determine if VM is turned on, and if not, start it up. Forcefully stop  and exit if it takes longer than $STARTWAIT to shutdown
	#

	SECONDS=0
	WAIT=0

	if ! virsh list | grep -q " ${DOMAIN} .*running"; then
    	DOMNOTRUNNING=true
    	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Starting ${DOMAIN} to begin backup process"|tee >(cat - >&5))
    	virsh start "$DOMAIN" > /dev/null
    	emaillog+="\n"$(echo -n "$(date +'%m/%d/%Y %H:%M:%S') Waiting for ${DOMAIN} to start"|tee >(cat - >&5))
    	while ! virsh list | grep -q " ${DOMAIN} .*running" ; do
        	if [ $WAIT -lt $STARTWAIT ]; then
            	emaillog+=$(echo -n "."|tee >(cat - >&5))
            	WAIT=$(($WAIT + 10))
            	sleep 10
        	else
		echo -e -n "\n"
		virsh destroy $DOMAIN > /dev/null
            	emaillog+="\n"$(echo -n "$(date +'%m/%d/%Y %H:%M:%S') Failed to start ${DOMAIN} - exiting."|tee >(cat - >&5))
	    	return 1
        	fi
    	done
        echo -e -n "\n"
	fi

	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Beginning backup for ${DOMAIN}"|tee >(cat - >&5))

	#
	# Generate the backup path
	#
	BACKUPDATE=`date "+%Y-%m-%d.%H%M%S"`
	BACKUPDOMAIN="$BACKUPDEST/$DOMAIN"
	BACKUP="$BACKUPDOMAIN/$BACKUPDATE"
	mkdir -p "$BACKUP"

	#
	# Get the list of targets (disks) and the image paths.
	#
	TARGETS=`virsh domblklist "$DOMAIN" --details | grep ^.file | grep -v 'cdrom' | grep -v 'floppy' | awk '{print $3}'`
	IMAGES=`virsh domblklist "$DOMAIN" --details | grep ^.file | grep -v 'cdrom' | grep -v 'floppy' | awk '{print $4}'`

	#
	# Create the snapshot.
	#
	DISKSPEC=""
	for t in $TARGETS; do
    	DISKSPEC="$DISKSPEC --diskspec $t,snapshot=external"
	done
	virsh snapshot-create-as --domain "$DOMAIN" --name backup --no-metadata \
		--atomic --disk-only $DISKSPEC >/dev/null
	if [ $? -ne 0 ]; then
    	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Failed to create snapshot for ${DOMAIN}"|tee >(cat - >&5))
    	return 1
	fi

	#
	# Copy disk images
	#
        IFS=$'\n'
	for t in $IMAGES; do
    	NAME=`basename "$t"`
    	cp "$t" "${BACKUP}/${NAME}"
	done

	#
	# Merge changes back.
	#
	BACKUPIMAGES=`virsh domblklist "$DOMAIN" --details | grep ^.file | grep -v 'cdrom' | grep -v 'floppy' | awk '{print $4}'`
	for t in $TARGETS; do
    	virsh blockcommit "$DOMAIN" "$t" --active --pivot >/dev/null
    	if [ $? -ne 0 ]; then
        	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Failed to merge changes for disk $t of ${DOMAIN}. VM may be in invalid state."|tee >(cat - >&5))
        	return 1
    	fi
	done

	#
	# Stop domain if it wasn't running at start of backup process. Forcefully stop if it takes longer than $STOPWAIT to shutdown
	#

	WAIT=0

	if [[ $DOMNOTRUNNING == "true" ]] ; then
    	virsh shutdown "$DOMAIN" > /dev/null
    	emaillog+="\n"$(echo -n "$(date +'%m/%d/%Y %H:%M:%S') Waiting for ${DOMAIN} to shut down"|tee >(cat - >&5))
    	while virsh list | grep -q " ${DOMAIN} .*running" ; do
		if [ $WAIT -lt $STOPWAIT ]; then
	    	emaillog+=$(echo -n "."|tee >(cat - >&5))
	    	WAIT=$(($WAIT + 10))
     	    	sleep 10
		else
                echo -e -n "\n"
	    	emaillog+="\n"$(echo -n "$(date +'%m/%d/%Y %H:%M:%S') Warning: ${DOMAIN} did not shut down within $STOPWAIT seconds - forcing shutdown"|tee >(cat - >&5))
	    	virsh destroy $DOMAIN > /dev/null
		fi
    	done
	echo -e -n "\n"
        emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Shut down of ${DOMAIN} completed"|tee >(cat - >&5))
	fi

	#
	# Cleanup left over backup images.
	#
	for t in $BACKUPIMAGES; do
    	rm -f "$t"
	done

	#
	# Dump the configuration information.
	#
	virsh dumpxml "$DOMAIN" >"$BACKUP/$DOMAIN.xml"

	#
	# Cleanup older backups.
	#
	LIST=`ls -r1 "$BACKUPDOMAIN" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$'`
	i=1
	for b in $LIST; do
    	if [ $i -gt "$MAXBACKUPS" ]; then
        	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Removing old backup "`basename $b`|tee >(cat - >&5))
        	rm -rf "$BACKUPDOMAIN/$b"
    	fi

    	i=$[$i+1]
	done

	#
	# Get backup size and backup duration for this domain
	#
	human_readable $(du -sb "$BACKUP" | cut -f1)
	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') ${DOMAIN} backup size: $HR_SIZE"|tee >(cat - >&5))
	emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') ${DOMAIN} backup duration: $(awk "BEGIN {printf \"%02d\", $SECONDS/3600}"):$(awk "BEGIN {printf \"%02d\",($SECONDS/60)%60}"):$(awk "BEGIN {printf \"%02d\", $SECONDS%60}")"|tee >(cat - >&5))
        emaillog+="\n"$(echo "$(date +'%m/%d/%Y %H:%M:%S') Finished backup of $DOMAIN"|tee >(cat - >&5))

        emailsummary+="\n"$(echo "${DOMAIN} backup size: $HR_SIZE")
        emailsummary+="\n"$(echo "${DOMAIN} backup duration: $(awk "BEGIN {printf \"%02d\", $SECONDS/3600}"):$(awk "BEGIN {printf \"%02d\",($SECONDS/60)%60}"):$(awk "BEGIN {printf \"%02d\", $SECONDS%60}")")"\n"
	#
	# Append total backup size and duration
	#
	TOTALSIZE=$(($TOTALSIZE + $(du -sb "$BACKUP" | cut -f1)))
	TOTALSECONDS=$(($TOTALSECONDS + $SECONDS))
}


if [[ "$DOMAINS" == "--all" ]]; then
	DOMAINS="$(virsh list --all --name|sed '/^\s*$/d')"
	while read -r domain; do
                domain_backup "$domain"
	done <<< $DOMAINS
else
	IFS=$'\n'
	for domain in $(echo "$DOMAINS" | sed "s/,/\\n/g")
	do
    		domain_backup "$domain"
	done
fi

#
# Get human readable backup size and print summary
#
human_readable $TOTALSIZE

if [[ $emaillog == *"Fail"* ]]; then
    SEVERITY="alert"
    SUBJECT="KVM Backup failed"
    DESCRIPTION="KVM Backup failed at $(date +'%m/%d/%Y %H:%M:%S')"
elif [[ $emaillog == *"Warning"* ]]; then
    SEVERITY="warning"
    SUBJECT="KVM Backup completed with warnings"
    DESCRIPTION="KVM Backup completed with warnings at $(date +'%m/%d/%Y %H:%M:%S')"
else
    SEVERITY="normal"
    SUBJECT="KVM Backup completed"
    DESCRIPTION="KVM Backup completed at $(date +'%m/%d/%Y %H:%M:%S')"
fi

emailsummary=$(echo "Total backup size: $HR_SIZE"|tee >(cat - >&5))"\n"$(echo "Total backup duration:  $(awk "BEGIN {printf \"%02d\", $TOTALSECONDS/3600}"):$(awk "BEGIN {printf \"%02d\", ($TOTALSECONDS/60)%60}"):$(awk "BEGIN {printf \"%02d\", $TOTALSECONDS%60}")"|tee >(cat - >&5))"\n\n"$emailsummary"\n"

/usr/local/emhttp/webGui/scripts/notify -i "$SEVERITY" -s "$SUBJECT" -d "$DESCRIPTION" -m "$emailsummary""$emaillog"
