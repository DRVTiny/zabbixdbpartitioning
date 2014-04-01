#!/bin/bash
#
# This script will partition your zabbix database to improve the efficiency.
# It will also create stored procedures to do the necessary housekeeping,
# and create a cronjob to do this on a daily basis
#
# This script inspired by the following:
#	http://zabbixzone.com/zabbix/partitioning-tables/
#
# While the basic SQL is from the above page, this script both creates the necessary 
# SQL for the desired tables, and can create new partitions as the time goes on
# assuming that the cronjob has been properly entered.
#
# 'GLOBAL' VARIABLES ->
SQL='/tmp/partition.sql'
PATHTOCRON='/usr/local/zabbix/cron.d'
PATHTOMAILBIN='/usr/bin/mail'
DUMP_FILE='/tmp/zabbix.sql'
DBHOST='localhost'
DBNAME='zabbix'
DBUSER='zabbix'
DBPASS='zabbix'
SIMULATE=0
NONINTERACTIVE=0
BACKUP=0
# Who to email with cron output by default
EMAIL='root@localhost'
# <- 'GLOBAL' VARIABLES
doShowUsage () {
 cat <<_EOF_

$0	[-H host][-u user][-p password][-d min_days][-y startyear][-n][-s][-e email_address][-b][-h]

	-H host			database host
	-u user			db user
	-p password		user password
	-d min_days		Minimum number of days of history to keep (default: ${history_min[daily]})
	-m min_months		Minimum number of months to keep trends (default: ${history_min[monthly]})
	-y startyear		First year to set up with partitions
	-n noninteractive	Run without questions - careful, make sure you know what is going to happen. Needs my.cnf with correct permissions.
	-b backup		Create backup of DB in $DUMP_FILE before alterations (only works with non-interactive mode, -n)
	-s simulate		Create SQL file that would be executed for examination ($SQL)
	-e email		Email address to receive partition update report (default: $EMAIL)
	-h 		        For this help message


After running this script, don't forget to disable housekeeping if
you didn't have the script disable it, and add the following cronjob

	### Option: DisableHousekeeping
	#       If set to 1, disables housekeeping.
	#
	# Mandatory: no
	# Range: 0-1
	################### Uncomment and change the following line to 1 in 
	################### Then restart the zabbix server
	DisableHousekeeping=1


Cron job

0 0 * * *  $PATHTOCRON/housekeeping.sh
_EOF_
	return 0
}

(( BASH_VERSINFO[0]<4 )) && {
 echo 'This script requires BASH 4 or newer' >&2
 exit 1
}

[[ $1 == '-x' ]] && {
 TRACE=1; shift; set -x
}

doCleaning () {
 local i
 for ((i=0; i<${#files2clean[@]}; i++)); do
  rm -f "${files2clean[$i]}"
 done
 return 0
}

declare -a files2clean=()
trap doCleaning EXIT

# How long to keep the daily history (days) and monthly history (months)
#
declare -A history_min=([daily]=90 [monthly]=12)

curDate=($(date +'%Y %m %d %H %M %S'))
declare -i first_year=${curDate[0]}
declare -i last_year=$first_year
cur_month=${curDate[1]}
if (( cur_month == 12 )); then
	last_year+=1
	cur_month=1
fi
y=$first_year

die () {
 echo "$1" >&2
 exit ${2:-1}
}

msg () {
 [[ $NONINTERACTIVE ]] || echo "$1" >&2
}
unset NONINTERACTIVE
declare -A hshDM=([d]='daily' [m]='monthly')

while getopts ': xhnsb H: m: e: u: p: d: y:' flag; do
	case $flag in
		H)	DBHOST=$OPTARG
		        host $DBHOST &>/dev/null || die "Host $DBHOST not accessible or 'host' utility not installed"
		;;
		x)      set -x; TRACE=1   ;;
		u)	DBUSER=$OPTARG    ;;
		p)	DBPASS=$OPTARG    ;;
		e)	EMAIL=$OPTARG     ;;
		s)	SIMULATE=1        ;;
		n)	NONINTERACTIVE=1  ;;
		b)	BACKUP=1          ;;
		[dm])	h=$OPTARG
		        (( h )) || die "Invalid ${hshDM[$flag]} history min, exiting"
			history_min[${hshDM[$flag]}]=$h
		;;
		y)	yy=$OPTARG
		        (( yy<y & yy>2000 )) || die 'Invalid year passed to me, exiting'
			first_year=$yy
		;;
		[\?h])	doShowUsage
		        [[ $flag == 'h' ]]
		        exit $? 
		;;
		*) doShowUsage; exit 1 ;;
	esac
done
shift $((OPTIND-1))

if [[ $SIMULATE -eq 0 ]]; then
	if [[ $NONINTERACTIVE ]]; then
		mysql -B -h $DBHOST -e "GRANT CREATE ROUTINE ON $DBNAME.* TO '$DBUSER'@'localhost';"
#		echo "GRANT LOCK TABLES ON zabbix.* TO '${DBUSER}'@'${DBHOST}' IDENTIFIED BY '${DBPASS}';" | mysql -h${DBHOST} -u${DBADMINUSER} --password=${DBADMINPASS}
                mysql -h $DBHOST -e "GRANT LOCK TABLES ON zabbix.* TO '$DBUSER'@'$DBHOST' IDENTIFIED BY '$DBPASS';"
		if [ $BACKUP = 1 ]; then
			mysqldump --opt -h $DBHOST -u $DBUSER -p$DBPASS zabbix --result-file=$DUMP_FILE
			rc=$?
			if [ $rc -ne 0 ]; then
				echo "Error during mysqldump, exit code: $rc"
			fi
		fi
	else
		echo -e "\nReady to update permissions of Zabbix user to create routines\n"
		echo -n "Enter root DB user: "
		read DBADMINUSER
		echo -n "Enter $DBADMINUSER password: "
		read DBADMINPASS
		mysql -B -h $DBHOST -u $DBADMINUSER -p$DBADMINPASS -e "GRANT CREATE ROUTINE ON zabbix.* TO '$DBUSER'@'localhost';"
		echo -e "\n"

		echo -ne "\nDo you want to backup the database (recommended) (Y/n): "
		read yn
		if [ "$yn" != "n" -a "$yn" != "N" ]; then
			echo -e "\nEnter output file, press return for default of $DUMP_FILE"
			read df
			[ "$df" != "" ] && DUMP_FILE=$df

			#
			# Lock tables is needed for a good mysqldump
			#
			echo "GRANT LOCK TABLES ON zabbix.* TO '${DBUSER}'@'${DBHOST}' IDENTIFIED BY '${DBPASS}';" | mysql -h${DBHOST} -u${DBADMINUSER} --password=${DBADMINPASS}

			mysqldump --opt -h ${DBHOST} -u ${DBUSER} -p${DBPASS} zabbix --result-file=${DUMP_FILE}
			rc=$?
			if [ $rc -ne 0 ]; then
				echo "Error during mysqldump, rc: $rc"
				echo "Do you wish to continue (y/N): "
				read yn
				[ "yn" != "y" -a "$yn" != "Y" ] && exit
			else
				echo "Mysqldump succeeded!, proceeding with upgrade..."
			fi
		else
			echo "Are you certain you have a backup (y/N): "
			read yn
			[ "$yn" != 'y' -a "$yn" != "Y" ] && exit
		fi
	fi
fi

if [[ $NONINTERACTIVE ]]; then
	yn='y'
else
	echo -e "\n\nReady to proceed:"

	echo -e "\nStarting yearly partioning at: $first_year"
	echo "and ending at: $last_year"
	echo "With ${history_min[daily]} days of daily history"
	echo -e "\n\nReady to proceed (Y/n): "
	read yn
	[ "$yn" = 'n' -o "$yn" = "N" ] && exit
fi


DAILY="history history_log history_str history_text history_uint"
DAILY_IDS="itemid id itemid id itemid"

MONTHLY="trends trends_uint"
MONTHLY_IDS=""

TABLES="$DAILY $MONTHLY"
IDS="$DAILY_IDS $MONTHLY_IDS"

if ! [[ $NONINTERACTIVE ]]; then
	echo "Use zabbix;  SELECT 'Altering tables';" >$SQL
else
	echo "Use zabbix;" >$SQL
fi
cnt=0
for i in $TABLES; do
	if ! [[ $NONINTERACTIVE ]]; then
		echo "Altering table: $i"
		echo "SELECT '$i';" >>$SQL
	fi
	cnt=$((cnt+1))
	case $i in
		history_log)
			echo "ALTER TABLE $i DROP KEY history_log_2;" >>$SQL
			echo "ALTER TABLE $i ADD KEY history_log_2(itemid, id);" >>$SQL
			echo "ALTER TABLE $i DROP PRIMARY KEY ;" >>$SQL
			id=`echo $IDS | cut -f$cnt -d" "`
			echo "ALTER TABLE $i ADD KEY ${i}id ($id);" >>$SQL
			;;
		history_text)
			echo "ALTER TABLE $i DROP KEY history_text_2;" >>$SQL
			echo "ALTER TABLE $i ADD KEY history_text_2 (itemid, clock);" >>$SQL
			echo "ALTER TABLE $i DROP PRIMARY KEY ;" >>$SQL
			id=`echo $IDS | cut -f$cnt -d" "`
			echo "ALTER TABLE $i ADD KEY ${i}id ($id);" >>$SQL
			;;
	esac
done

echo -en "\n" >>$SQL
for i in $MONTHLY; do
	if ! [[ $NONINTERACTIVE ]]; then
		echo "Creating monthly partitions for table: $i"
		echo "SELECT '$i';" >>$SQL
	fi
	echo "ALTER TABLE $i PARTITION BY RANGE( clock ) (" >>$SQL
	for y in `seq $first_year $last_year`; do
		last_month=12
		(( y == last_year )) && last_month=$((cur_month+1))
		for m in `seq 1 $last_month`; do
			[ $m -lt 10 ] && m="0$m"
			ms=`date +"%Y-%m-01" -d "$m/01/$y +1 month"`
			pname="p${y}${m}"
			echo -n "PARTITION $pname  VALUES LESS THAN (UNIX_TIMESTAMP(\"$ms 00:00:00\"))" >>$SQL
			[ $m -ne $last_month -o $y -ne $last_year ] && echo -n "," >>$SQL
			echo -ne "\n" >>$SQL
		done
	done
	echo ");" >>$SQL
done

for i in $DAILY; do
	if ! [[ $NONINTERACTIVE ]]; then
		echo "Creating daily partitions for table: $i"
		echo "SELECT '$i';" >>$SQL
	fi
	echo "ALTER TABLE $i PARTITION BY RANGE( clock ) (" >>$SQL
	for d in `seq -${history_min[daily]} 2`; do
		ds=`date +"%Y-%m-%d" -d "$d day +1 day"`
		pname=`date +"%Y%m%d" -d "$d day"`
		echo -n "PARTITION p$pname  VALUES LESS THAN (UNIX_TIMESTAMP(\"$ds 00:00:00\"))" >>$SQL
		[ $d -ne 2 ] && echo -n "," >>$SQL
		echo -ne "\n" >>$SQL
	done
	echo ");" >>$SQL
done



###############################################################
if ! [[ $NONINTERACTIVE ]]; then
	cat >>$SQL <<_EOF_
SELECT "Installing procedures";
_EOF_
fi

cat >>$SQL <<_EOF_
/**************************************************************
  MySQL Auto Partitioning Procedure for Zabbix 1.8
  http://zabbixzone.com/zabbix/partitioning-tables/

  Author:  Ricardo Santos (rsantos at gmail.com)
  Version: 20110518
**************************************************************/
DELIMITER //
DROP PROCEDURE IF EXISTS zabbix.create_zabbix_partitions; //
CREATE PROCEDURE zabbix.create_zabbix_partitions ()
BEGIN
_EOF_

###############################################################

for i in $DAILY; do
	echo "	CALL zabbix.create_next_partitions(\"zabbix\",\"$i\");" >>$SQL
	echo "	CALL zabbix.drop_old_partitions(\"zabbix\",\"$i\");" >>$SQL
done
echo -en "\n" >>$SQL
for i in $MONTHLY; do
	echo "	CALL zabbix.create_next_monthly_partitions(\"zabbix\",\"$i\");" >>$SQL
	echo "	CALL zabbix.drop_old_monthly_partitions(\"zabbix\",\"$i\");" >>$SQL
done

###############################################################
cat >>$SQL <<_EOF_
END //

DROP PROCEDURE IF EXISTS zabbix.create_next_partitions; //
CREATE PROCEDURE zabbix.create_next_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
	DECLARE NEXTCLOCK timestamp;
	DECLARE PARTITIONNAME varchar(16);
	DECLARE CLOCK int;
	SET @totaldays = 7;
	SET @i = 1;
	createloop: LOOP
		SET NEXTCLOCK = DATE_ADD(NOW(),INTERVAL @i DAY);
		SET PARTITIONNAME = DATE_FORMAT( NEXTCLOCK, 'p%Y%m%d' );
		SET CLOCK = UNIX_TIMESTAMP(DATE_FORMAT(DATE_ADD( NEXTCLOCK ,INTERVAL 1 DAY),'%Y-%m-%d 00:00:00'));
		CALL zabbix.create_partition( SCHEMANAME, TABLENAME, PARTITIONNAME, CLOCK );
		SET @i=@i+1;
		IF @i > @totaldays THEN
			LEAVE createloop;
		END IF;
	END LOOP;
END //


DROP PROCEDURE IF EXISTS zabbix.drop_old_partitions; //
CREATE PROCEDURE zabbix.drop_old_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
	DECLARE OLDCLOCK timestamp;
	DECLARE PARTITIONNAME varchar(16);
	DECLARE CLOCK int;
	SET @mindays = ${history_min[daily]};
	SET @maxdays = @mindays+4;
	SET @i = @maxdays;
	droploop: LOOP
		SET OLDCLOCK = DATE_SUB(NOW(),INTERVAL @i DAY);
		SET PARTITIONNAME = DATE_FORMAT( OLDCLOCK, 'p%Y%m%d' );
		CALL zabbix.drop_partition( SCHEMANAME, TABLENAME, PARTITIONNAME );
		SET @i=@i-1;
		IF @i <= @mindays THEN
			LEAVE droploop;
		END IF;
	END LOOP;
END //

DROP PROCEDURE IF EXISTS zabbix.create_next_monthly_partitions; //
CREATE PROCEDURE zabbix.create_next_monthly_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
	DECLARE NEXTCLOCK timestamp;
	DECLARE PARTITIONNAME varchar(16);
	DECLARE CLOCK int;
	SET @totalmonths = 3;
	SET @i = 1;
	createloop: LOOP
		SET NEXTCLOCK = DATE_ADD(NOW(),INTERVAL @i MONTH);
		SET PARTITIONNAME = DATE_FORMAT( NEXTCLOCK, 'p%Y%m' );
		SET CLOCK = UNIX_TIMESTAMP(DATE_FORMAT(DATE_ADD( NEXTCLOCK ,INTERVAL 1 MONTH),'%Y-%m-01 00:00:00'));
		CALL zabbix.create_partition( SCHEMANAME, TABLENAME, PARTITIONNAME, CLOCK );
		SET @i=@i+1;
		IF @i > @totalmonths THEN
			LEAVE createloop;
		END IF;
	END LOOP;
END //

DROP PROCEDURE IF EXISTS zabbix.drop_old_monthly_partitions; //
CREATE PROCEDURE zabbix.drop_old_monthly_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
	DECLARE OLDCLOCK timestamp;
	DECLARE PARTITIONNAME varchar(16);
	DECLARE CLOCK int;
	SET @minmonths = ${history_min[monthly]};
	SET @maxmonths = @minmonths+24;
	SET @i = @maxmonths;
	droploop: LOOP
		SET OLDCLOCK = DATE_SUB(NOW(),INTERVAL @i MONTH);
		SET PARTITIONNAME = DATE_FORMAT( OLDCLOCK, 'p%Y%m' );
		CALL zabbix.drop_partition( SCHEMANAME, TABLENAME, PARTITIONNAME );
		SET @i=@i-1;
		IF @i <= @minmonths THEN
			LEAVE droploop;
		END IF;
	END LOOP;
END //

DROP PROCEDURE IF EXISTS zabbix.create_partition; //
CREATE PROCEDURE zabbix.create_partition (SCHEMANAME varchar(64), TABLENAME varchar(64), PARTITIONNAME varchar(64), CLOCK int)
BEGIN
	DECLARE RETROWS int;
	SELECT COUNT(1) INTO RETROWS
		FROM information_schema.partitions
		WHERE table_schema = SCHEMANAME AND table_name = TABLENAME AND partition_name = PARTITIONNAME;

	IF RETROWS = 0 THEN
		SELECT CONCAT( "create_partition(", SCHEMANAME, ",", TABLENAME, ",", PARTITIONNAME, ",", CLOCK, ")" ) AS msg;
     		SET @sql = CONCAT( 'ALTER TABLE ', SCHEMANAME, '.', TABLENAME, 
				' ADD PARTITION (PARTITION ', PARTITIONNAME, ' VALUES LESS THAN (', CLOCK, '));' );
		PREPARE STMT FROM @sql;
		EXECUTE STMT;
		DEALLOCATE PREPARE STMT;
	END IF;
END //

DROP PROCEDURE IF EXISTS zabbix.drop_partition; //
CREATE PROCEDURE zabbix.drop_partition (SCHEMANAME varchar(64), TABLENAME varchar(64), PARTITIONNAME varchar(64))
BEGIN
	DECLARE RETROWS int;
	SELECT COUNT(1) INTO RETROWS
		FROM information_schema.partitions
		WHERE table_schema = SCHEMANAME AND table_name = TABLENAME AND partition_name = PARTITIONNAME;

	IF RETROWS = 1 THEN
		SELECT CONCAT( "drop_partition(", SCHEMANAME, ",", TABLENAME, ",", PARTITIONNAME, ")" ) AS msg;
     		SET @sql = CONCAT( 'ALTER TABLE ', SCHEMANAME, '.', TABLENAME,
				' DROP PARTITION ', PARTITIONNAME, ';' );
		PREPARE STMT FROM @sql;
		EXECUTE STMT;
		DEALLOCATE PREPARE STMT;
	END IF;
END //
DELIMITER ;
_EOF_

if [ $SIMULATE = 1 ]; then
	exit 0
fi

if [[ $NONINTERACTIVE ]]; then
	yn='y'
else
	echo -e "\n\nReady to apply script to database, this may take a while.(Y/n): "
	read yn
fi
if [ "$yn" != "n" -a "$yn" != "N" ]; then
	mysql --skip-column-names -h ${DBHOST} -u ${DBUSER} -p${DBPASS} <$SQL
fi

conf=/etc/zabbix/zabbix_server.conf
if [[ $NONINTERACTIVE ]]; then
	yn='y'
else
	echo -e "\nDo you want to update the /etc/zabbix/zabbix_server.conf"
	echo -n "to disable housekeeping (Y/n): "
	read yn
fi
if [ "$yn" != "n" -a "$yn" != "N" ]; then
	cp $conf ${conf}.bak
	sed  -i "s/^# DisableHousekeeping=0/DisableHousekeeping=1/" $conf
	sed  -i "s/^DisableHousekeeping=0/DisableHousekeeping=1/" $conf
	/etc/init.d/zabbix-server stop
	sleep 5
	/etc/init.d/zabbix-server start 2>&1 > /dev/null
fi

tmpfile=$(mktemp /tmp/XXXXXXXXXXXXX)
files2clean+=("$tmpfile")

if [[ $NONINTERACTIVE ]]; then
	yn='y'
else
	echo -ne '\nDo you want to update the crontab (Y/n): '
	read yn
fi
if [[ $yn =~ ^[Nn]$ ]]; then
	where=''
	until [[ $where ]]; do
		if [[ $NONINTERACTIVE ]]; then
			where='Y'
		else
		        
			echo -e 'The crontab entry can be either in /etc/cron.daily, or added\nto the crontab for root\n'
			echo -n 'Do you want to add this to the /etc/cron.daily directory (Y/n): '
			read where
		fi
		where=${where:-Y}; where=${where^^}; where=${where:0:1}
		if ! [[ $where =~ ^[YN]$ ]]; then
			unset where
			echo 'Response not recognized, please try again' >&2
		fi
	done

	if ! [[ $NONINTERACTIVE ]]; then
		echo -en "\nEnter email of who should get the daily housekeeping reports [$EMAIL]: "
		read mailto
	fi
	mailto=${mailto:-$EMAIL}
	mkdir -p $PATHTOCRON
	cat >$PATHTOCRON/housekeeping.sh <<_EOF_
#!/bin/bash

MAILTO=$mailto
tmpfile=\$(mktemp /tmp/XXXXXXXXXXXXXX)

date >\$tmpfile
/usr/bin/mysql --skip-column-names -B -h $DBHOST -u $DBUSER -p"$DBPASS" $DBNAME -e "CALL create_zabbix_partitions();" >>\$tmpfile 2>&1
$PATHTOMAILBIN -s "Zabbix MySql Partition Housekeeping" \$MAILTO <\$tmpfile
rm -f \$tmpfile
_EOF_
	chmod +x $PATHTOCRON/housekeeping.sh
	chown -R zabbix.zabbix /usr/local/zabbix
	if [[ $where == 'Y' ]]; then
		cat >/etc/cron.daily/zabbixhousekeeping <<_EOF_
#!/bin/bash
$PATHTOCRON/housekeeping.sh
_EOF_
		chmod +x /etc/cron.daily/zabbixhousekeeping
	else
		crontab -l >$tmpfile
		cat >>$tmpfile <<_EOF_
0 0 * * *  $PATHTOCRON/housekeeping.sh
_EOF_
		crontab $tmpfile
		rm $tmpfile
	fi
fi
