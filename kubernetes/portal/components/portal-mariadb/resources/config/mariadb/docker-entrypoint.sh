#!/bin/bash

set -eo pipefail
shopt -s nullglob

# logging functions
mysql_log() {
    local type="$1"; shift
    printf '%s [%s] [Entrypoint]: %s\n' "$(date --rfc-3339=seconds)" "$type" "$*"
}
mysql_note() {
    mysql_log Note "$@"
}
mysql_warn() {
    mysql_log Warn "$@" >&2
}
mysql_error() {
    mysql_log ERROR "$@" >&2
    exit 1
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        mysql_error "Both $var and $fileVar are set (but are exclusive)"
    fi
    local val="$def"
    # val="${!var}"
    # val="$(< "${!fileVar}")"
    # eval replacement of the bashism equivalents above presents no security issue here
    # since var and fileVar variables contents are derived from the file_env() function arguments.
    # This method is only called inside this script with a limited number of possible values.
    if [ "${!var:-}" ]; then
        eval val=\$$var
    elif [ "${!fileVar:-}" ]; then
        val="$(< "$(eval echo "\$$fileVar")")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
    # https://unix.stackexchange.com/a/215279
    [ "${#FUNCNAME[@]}" -ge 2 ] \
        && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
        && [ "${FUNCNAME[1]}" = 'source' ]
}

# usage: docker_process_init_files [file [file [...]]]
#    ie: docker_process_init_files /always-initdb.d/*
# process initializer files, based on file extensions
docker_process_init_files() {
    # mysql here for backwards compatibility "${mysql[@]}"
    mysql=( docker_process_sql )

    echo
    local f
    for f; do
        case "$f" in
            *.sh)
                # https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
                # https://github.com/docker-library/postgres/pull/452
                if [ -x "$f" ]; then
                    mysql_note "$0: running $f"
                    "$f"
                else
                    mysql_note "$0: sourcing $f"
                    . "$f"
                fi
                ;;
            *.sql)    mysql_note "$0: running $f"; docker_process_sql < "$f"; echo ;;
            *.sql.gz) mysql_note "$0: running $f"; gunzip -c "$f" | docker_process_sql; echo ;;
            *.sql.xz) mysql_note "$0: running $f"; xzcat "$f" | docker_process_sql; echo ;;
            *)        mysql_warn "$0: ignoring $f" ;;
        esac
        echo
    done
}

mysql_check_config() {
    local toRun=( "$@" --verbose --help --log-bin-index="$(mktemp -u)" ) errors
    if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
        mysql_error "$(printf 'mysqld failed while attempting to check config\n\tcommand was: ')${toRun[*]}$(printf'\n\t')$errors"
    fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
mysql_get_config() {
    local conf="$1"; shift
    "$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
        | awk -v conf="$conf" '$1 == conf && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
    # match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

# Do a temporary startup of the MySQL server, for init purposes
docker_temp_server_start() {
    "$@" --skip-networking --socket="${SOCKET}" &
    mysql_note "Waiting for server startup"
    local i
    for i in $(seq 30 -1 0); do
        # only use the root password if the database has already been initializaed
        # so that it won't try to fill in a password file when it hasn't been set yet
        extraArgs=""
        if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
            extraArgs=${extraArgs}" --dont-use-mysql-root-password"
        fi
        if echo 'SELECT 1' |docker_process_sql ${extraArgs} --database=mysql >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if [ "$i" = 0 ]; then
        mysql_error "Unable to start server."
    fi
}

# Stop the server. When using a local socket file mysqladmin will block until
# the shutdown is complete.
docker_temp_server_stop() {
    if ! mysqladmin --defaults-extra-file=<( _mysql_passfile ) shutdown -uroot --socket="${SOCKET}"; then
        mysql_error "Unable to shut down server."
    fi
}

# Verify that the minimally required password settings are set for new databases.
docker_verify_minimum_env() {
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        mysql_error "$(printf'Database is uninitialized and password option is not specified\n\tYou need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD')"
    fi
}

# creates folders for the database
# also ensures permission for user mysql of run as root
docker_create_db_directories() {
    local user; user="$(id -u)"

    # TODO other directories that are used by default? like /var/lib/mysql-files
    # see https://github.com/docker-library/mysql/issues/562
    mkdir -p "$DATADIR"

    if [ "$user" = "0" ]; then
        # this will cause less disk access than `chown -R`
        find "$DATADIR" \! -user mysql -exec chown mysql '{}' +
    fi
}

# initializes the database directory
docker_init_database_dir() {
    mysql_note "Initializing database files"
    installArgs=" --datadir=$DATADIR --rpm "
    if { mysql_install_db --help || :; } | grep -q -- '--auth-root-authentication-method'; then
        # beginning in 10.4.3, install_db uses "socket" which only allows system user root to connect, switch back to "normal" to allow mysql root without a password
        # see https://github.com/MariaDB/server/commit/b9f3f06857ac6f9105dc65caae19782f09b47fb3
        # (this flag doesn't exist in 10.0 and below)
        installArgs=${installArgs}" --auth-root-authentication-method=normal"
    fi
    # "Other options are passed to mysqld." (so we pass all "mysqld" arguments directly here)
    mysql_install_db ${installArgs} "$(echo ${@} | sed 's/^ *[^ ]* *//')"
    mysql_note "Database files initialized"
}

# Loads various settings that are used elsewhere in the script
# This should be called after mysql_check_config, but before any other functions
docker_setup_env() {
    # Get config
    declare -g DATADIR SOCKET
    DATADIR="$(mysql_get_config 'datadir' "$@")"
    SOCKET="$(mysql_get_config 'socket' "$@")"

    # Initialize values that might be stored in a file
    file_env 'MYSQL_ROOT_HOST' '%'
    file_env 'MYSQL_DATABASE'
    file_env 'MYSQL_USER'
    file_env 'MYSQL_PASSWORD'
    file_env 'MYSQL_ROOT_PASSWORD'
    file_env 'PORTAL_DB_TABLES'

    declare -g DATABASE_ALREADY_EXISTS
    if [ -d "$DATADIR/mysql" ]; then
        DATABASE_ALREADY_EXISTS='true'
    fi
}

# Execute sql script, passed via stdin
# usage: docker_process_sql [--dont-use-mysql-root-password] [mysql-cli-args]
#    ie: docker_process_sql --database=mydb <<<'INSERT ...'
#    ie: docker_process_sql --dont-use-mysql-root-password --database=mydb <my-file.sql
docker_process_sql() {
    passfileArgs=""
    if [ '--dont-use-mysql-root-password' = "$1" ]; then
        passfileArgs=${passfileArgs}" $1"
        shift
    fi
    # args sent in can override this db, since they will be later in the command
    if [ -n "$MYSQL_DATABASE" ]; then
        set -- --database="$MYSQL_DATABASE" "$@"
    fi

    mysql --defaults-extra-file=<( _mysql_passfile ${passfileArgs}) --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" "$@"
}

# Initializes database with timezone info and root password, plus optional extra db/user
docker_setup_db() {
    # Load timezone info into database
    if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
        {
            # Aria in 10.4+ is slow due to "transactional" (crash safety)
            # https://jira.mariadb.org/browse/MDEV-23326
            # https://github.com/docker-library/mariadb/issues/262
            local tztables=( time_zone time_zone_leap_second time_zone_name time_zone_transition time_zone_transition_type )
            for table in "${tztables[@]}"; do
                echo "/*!100400 ALTER TABLE $table TRANSACTIONAL=0 */;"
            done

            # sed is for https://bugs.mysql.com/bug.php?id=20545
            mysql_tzinfo_to_sql /usr/share/zoneinfo \
                | sed 's/Local time zone must be set--see zic manual page/FCTY/'

            for table in "${tztables[@]}"; do
                echo "/*!100400 ALTER TABLE $table TRANSACTIONAL=1 */;"
            done
        } | docker_process_sql --dont-use-mysql-root-password --database=mysql
        # tell docker_process_sql to not use MYSQL_ROOT_PASSWORD since it is not set yet
    fi
    # Generate random root password
    if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
        mysql_note "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi
    # Sets root password and creates root users for non-localhost hosts
    local rootCreate=
    # default root to listen for connections from anywhere
    if [ -n "$MYSQL_ROOT_HOST" ] && [ "$MYSQL_ROOT_HOST" != 'localhost' ]; then
        # no, we don't care if read finds a terminating character in this heredoc
        # https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
        read -r -d '' rootCreate <<-EOSQL || true
            CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
            GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
EOSQL
    fi

    # tell docker_process_sql to not use MYSQL_ROOT_PASSWORD since it is just now being set
    docker_process_sql --dont-use-mysql-root-password --database=mysql <<-EOSQL
        -- What's done in this file shouldn't be replicated
        --  or products like mysql-fabric won't work
        SET @@SESSION.SQL_LOG_BIN=0;

        DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mariadb.sys', 'mysqlxsys', 'root') OR host NOT IN ('localhost') ;
        SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
        -- 10.1: https://github.com/MariaDB/server/blob/d925aec1c10cebf6c34825a7de50afe4e630aff4/scripts/mysql_secure_installation.sh#L347-L365
        -- 10.5: https://github.com/MariaDB/server/blob/00c3a28820c67c37ebbca72691f4897b57f2eed5/scripts/mysql_secure_installation.sh#L351-L369
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%' ;

        GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
        FLUSH PRIVILEGES ;
        ${rootCreate}
        DROP DATABASE IF EXISTS test ;
EOSQL

    # Creates a custom database and user if specified
    if [ -n "$MYSQL_DATABASE" ]; then
        mysql_note "Creating database ${MYSQL_DATABASE}"
        echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" |docker_process_sql --database=mysql
    fi

    if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
        mysql_note "Creating user ${MYSQL_USER}"
        echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" |docker_process_sql --database=mysql

        if [ -n "$MYSQL_DATABASE" ]; then
            mysql_note "Giving user ${MYSQL_USER} access to schema ${MYSQL_DATABASE}"
            echo "GRANT ALL ON \`$(echo $MYSQL_DATABASE | sed 's@_@\\_@g')\`.* TO '$MYSQL_USER'@'%' ;" | docker_process_sql --database=mysql
        fi

        echo "FLUSH PRIVILEGES ;" | docker_process_sql --database=mysql
    fi
}

_mysql_passfile() {
    # echo the password to the "file" the client uses
    # the client command will use process substitution to create a file on the fly
    # ie: --defaults-extra-file=<( _mysql_passfile )
    if [ '--dont-use-mysql-root-password' != "$1" ] && [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        cat <<-EOF
            [client]
            password="${MYSQL_ROOT_PASSWORD}"
EOF
    fi
}

# check arguments for an option that would cause mysqld to stop
# return true if there is one
_mysql_want_help() {
    local arg
    for arg; do
        case "$arg" in
            -'?'|--help|--print-defaults|-V|--version)
                return 0
                ;;
        esac
    done
    return 1
}

_main() {
    # if command starts with an option, prepend mysqld
    if echo "$1" | grep '^-' >/dev/null; then
        set -- mysqld "$@"
    fi

    # skip setup if they aren't running mysqld or want an option that stops mysqld
    if [ "$1" = 'mysqld' ] && ! _mysql_want_help "$@"; then
        mysql_note "Entrypoint script for MySQL Server ${MARIADB_VERSION} started."

        mysql_check_config "$@"
        # Load various environment variables
        docker_setup_env "$@"
        docker_create_db_directories

        # If container is started as root user, restart as dedicated mysql user
        if [ "$(id -u)" = "0" ]; then
            mysql_note "Switching to dedicated user 'mysql'"
            exec gosu mysql "$0" "$@"
        fi

        # there's no database, so it needs to be initialized
        if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
            docker_verify_minimum_env

            # check dir permissions to reduce likelihood of half-initialized database
            ls /docker-entrypoint-initdb.d/ > /dev/null

            docker_init_database_dir "$@"

            mysql_note "Starting temporary server"
            docker_temp_server_start "$@"
            mysql_note "Temporary server started."

            docker_setup_db
            docker_process_init_files /docker-entrypoint-initdb.d/*

            for i in $(echo $PORTAL_DB_TABLES | sed "s/,/ /g")
                do
                    echo "Granting portal user ALL PRIVILEGES for table $i"
                    echo "GRANT ALL ON \`$i\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
                done

            mysql_note "Stopping temporary server"
            docker_temp_server_stop
            mysql_note "Temporary server stopped"

            echo
            mysql_note "MySQL init process done. Ready for start up."
            echo
        fi
    fi
    exec "$@"
}

# If we are sourced from elsewhere, don't perform any further actions
if ! _is_sourced; then
    _main "$@"
fi
