#!/bin/bash
reset
PGROOT=/pgdata
PREFIX=$PGROOT
PGDATA=${PGROOT}/base

echo "

		PREFIX=$PREFIX
        PGDATA=$PGDATA

"

if echo "$@"|grep -q clean
then
	make clean
	rm $(find |grep \\.js$) $(find |grep \\.wasm$)
	if echo "$@"|grep distclean
	then
		exit 0
	fi
fi

if echo "$@"|grep -q patchwork
then
    echo "


        applying patchwork from https://github.com/pmp-p/postgres-patchwork/issues?q=is%3Aissue+is%3Aopen+label%3Apatch


"
    wget -O- https://patch-diff.githubusercontent.com/raw/pmp-p/postgres-patchwork/pull/2.diff | patch -p1
    wget -O- https://patch-diff.githubusercontent.com/raw/pmp-p/postgres-patchwork/pull/5.diff | patch -p1
    wget -O- https://patch-diff.githubusercontent.com/raw/pmp-p/postgres-patchwork/pull/7.diff | patch -p1
    sudo mkdir /pgdata
    sudo chmod 777 /pgdata
    exit 0
fi


mkdir -p ${PREFIX}


cat > ${PREFIX}/config.site <<END
END

#  --with-blocksize=8 --with-segsize=1 --with-segsize-blocks=0 --with-wal-blocksize=8 \
#



CNF="./configure --prefix=${PREFIX} \
 --disable-spinlocks --disable-atomics --without-zlib --disable-largefile --without-llvm \
 --without-readline --without-icu \
 --without-pam --disable-largefile --without-zlib --with-openssl=no \
 --enable-debug"



if echo "$@" |grep native
then

	make distclean
	echo "         =============== building host native ===================   "
	CONFIG_SITE=${PREFIX}/config.site CC="clang" CXX="clang++" CFLAGS="-m32" $CNF --with-template=linux && make && make install

	if pushd ${PREFIX}
	then
		cp bin/postgres bin/postgres.native

		cat > ${PREFIX}/bin/postgres <<END
#!/bin/bash
unset LD_PRELOAD
PGDATA=${PGDATA}
echo "# \$@" >> ${PREFIX}/journal.sql
tee -a ${PREFIX}/journal.sql | ${PREFIX}/bin/postgres.native \$@
END

		chmod +x ${PREFIX}/bin/postgres

		# 32bits build run initdb
		unset LD_PRELOAD

		rm -rf base/
		> ${PREFIX}/journal.sql

		TZ=UTC ${PREFIX}/bin/initdb -g -N -U postgres --pwfile=${PREFIX}/password -E UTF8 --locale=C --locale-provider=libc --pgdata=${PGDATA}

		mkdir -p base-native/ base-wasm/
		cp -rf base/* base-native/
		popd
	fi
	sync
	echo "initdb-native done"
	make distclean 2>&1 >/dev/null
	exit 0
fi


if echo "$@" |grep wasi
then
	. /opt/python-wasm-sdk/wasisdk/wasisdk_env.sh
	echo "      =============== building wasi  ===================   "
	#make distclean

	CONFIG_SITE=${PREFIX}/config.site CC="wasi-c" CXX="wasi-c++" $CNF --cache-file=../config.wasi && make
	# && make install

	exit 0
fi





echo "      =============== building wasm  ===================   "

. /opt/python-wasm-sdk/wasm32-bi-emscripten-shell.sh
# was erased, default pfx is sdk dir
export PREFIX=$PGROOT


# -lwebsocket.js -sPROXY_POSIX_SOCKETS -pthread -sPROXY_TO_PTHREAD
# CONFIG_SITE=$(pwd)/config.site EMCC_CFLAGS="--oformat=html" \

# --disable-shared is not supported

CONFIG_SITE==${PGDATA}/config.site  emconfigure $CNF  --with-template=emscripten --cache-file=../config.emsdk $@


sed -i 's|ZIC= ./zic|ZIC= zic|g' ./src/timezone/Makefile

mkdir bin

cat > bin/zic <<END
#!/bin/bash
. /opt/python-wasm-sdk/wasm32-bi-emscripten-shell.sh
node $(pwd)/src/timezone/zic \$@
END

> /tmp/disable-shared.log

# --disable-shared not supported so use a fake linker

cat > bin/disable-shared <<END
#!/bin/bash
echo "[\$(pwd)] $0 \$@" >> /tmp/disable-shared.log
for arg do
    shift
    if [ "\$arg" = "-o" ]
    then
        continue
    fi
    if echo "\$arg" | grep -q ^-
    then
        continue
    fi
    if echo "\$arg" | grep -q \\\\.o$
    then
        continue
    fi
    set -- "\$@" "\$arg"
done
touch \$@
END

# FIXME: workaround for /conversion_procs/ make
cp bin/disable-shared bin/o

chmod +x bin/zic bin/disable-shared bin/o

rm /srv/www/html/pygbag/pg/libpq.so /srv/www/html/pygbag/pg/libpq.so.map

if [ -f $(pwd)/wasmfix.h ]
then
    export EMCC_CFLAGS="-include $(pwd)/wasmfix.h -sNODERAWFS"
else
    export EMCC_CFLAGS="-sNODERAWFS"
fi

rm ./src/backend/postgres.wasm

# for zic and disable-shared
PATH=$(pwd)/bin:$PATH

if emmake make -j 6
then

	if emmake make install
	then

		mv -vf ./src/bin/initdb/initdb.wasm ./src/backend/postgres.wasm ./src/backend/postgres.map ${PREFIX}/bin/
		mv -vf ./src/bin/initdb/initdb ${PREFIX}/bin/initdb.js
		mv -vf ./src/backend/postgres ${PREFIX}/bin/postgres.js


cat  > ${PREFIX}/bin/postgres <<END
#!/bin/bash
. /opt/python-wasm-sdk/wasm32-bi-emscripten-shell.sh
PGDATA=${PGDATA} node ${PREFIX}/bin/postgres.js \$@
END

		cat  > ${PREFIX}/bin/initdb <<END
#!/bin/bash
. /opt/python-wasm-sdk/wasm32-bi-emscripten-shell.sh
node ${PREFIX}/bin/initdb.js \$@
END

		chmod +x ${PREFIX}/bin/postgres ${PREFIX}/bin/initdb

		echo "initdb for PGDATA=${PGDATA} "

	fi

	cat >$PREFIX/initdb.sh <<END
#!/bin/bash
rm -rf ${PGDATA} /tmp/initdb-*.log
TZ=UTC
${PREFIX}/initdb -k -g -N -U postgres --pwfile=${PREFIX}/password --locale=C --locale-provider=libc --pgdata=${PGDATA} 2> /tmp/initdb-\$\$.log
echo "Ready to run sql command through ${PREFIX}/postgres"
grep -v ^initdb.js /tmp/initdb-\$\$.log \\
 | tail -n +4 \\
 | head -n -1 \\
 > /tmp/initdb-\$\$.sql

md5sum /tmp/initdb-\$\$.sql

${PREFIX}/postgres --boot -d 1 -c log_checkpoints=false -X 16777216 -k < /tmp/initdb-\$\$.sql 2>&1 | grep -v 'bootstrap>'
echo cleaning up sql journal
rm /tmp/initdb-\$\$.log /tmp/initdb-\$\$.sql
END

	chmod +x $PREFIX/*.sh

	$PREFIX/initdb.sh
	echo "initdb done, now init sql default database"

	if [ -f ${PGDATA}/postmaster.pid ]
	then
		cat > $PREFIX/initsql.sh <<END
cat $(realpath ../initdb.sql) | ${PREFIX}/postgres --single -F -O -j -c search_path=pg_catalog -c exit_on_error=true -c log_checkpoints=false template1
END

		chmod +x $PREFIX/*.sh

		read

		$PREFIX/initsql.sh
		rm $PGDATA/postmaster.pid
	fi

    mkdir -p ${PREFIX}/lib
    rm ${PREFIX}/lib/lib*.so.* ${PREFIX}/lib/libpq.so

  	emcc -shared -o ${PREFIX}/lib/libpq.so \
     ./src/interfaces/libpq/libpq.a \
     ./src/port/libpgport.a \
     ./src/common/libpgcommon.a

    if [ -f /data/git/pg/local.sh ]
    then
        . /data/git/pg/local.sh
    fi

    echo "========================================================="

    file ${PREFIX}/lib/lib*.so

else
    echo build failed
fi
