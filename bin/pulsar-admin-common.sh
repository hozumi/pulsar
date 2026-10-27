#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

DEFAULT_CLIENT_CONF=$PULSAR_HOME/conf/client.conf
DEFAULT_LOG_CONF=$PULSAR_HOME/conf/log4j2.yaml

if [ -f "$PULSAR_HOME/conf/pulsar_tools_env.sh" ]
then
    . "$PULSAR_HOME/conf/pulsar_tools_env.sh"
fi

# Check for the java to use
if [[ -z $JAVA_HOME ]]; then
    JAVA=$(which java)
    if [ $? != 0 ]; then
        echo "Error: JAVA_HOME not set, and no java executable found in $PATH." 1>&2
        exit 1
    fi
else
    JAVA=$JAVA_HOME/bin/java
fi

for token in $("$JAVA" -version 2>&1 | grep 'version "'); do
    if [[ $token =~ \"([[:digit:]]+)\.([[:digit:]]+)(.*)\" ]]; then
        if [[ ${BASH_REMATCH[1]} == "1" ]]; then
          JAVA_MAJOR_VERSION=${BASH_REMATCH[2]}
        else
          JAVA_MAJOR_VERSION=${BASH_REMATCH[1]}
        fi
        break
    elif [[ $token =~ \"([[:digit:]]+)(.*)\" ]]; then
        # Process the java versions without dots, such as `17-internal`.
        JAVA_MAJOR_VERSION=${BASH_REMATCH[1]}
        break
    fi
done

# exclude tests jar
RELEASE_JAR=`ls $PULSAR_HOME/pulsar-*.jar 2> /dev/null | grep -v tests | tail -1`
if [ $? == 0 ]; then
    PULSAR_JAR=$RELEASE_JAR
fi

# exclude tests jar
BUILT_JAR=`ls $PULSAR_HOME/pulsar-client-tools/build/libs/pulsar-client-tools-*.jar 2> /dev/null | grep -v tests | tail -1`
if [ $? != 0 ] && [ ! -e "$PULSAR_JAR" ]; then
    echo "\nCouldn't find pulsar jar.";
    echo "Make sure you've run './gradlew assemble'\n";
    exit 1;
elif [ -e "$BUILT_JAR" ]; then
    PULSAR_JAR=$BUILT_JAR
fi

add_gradle_deps_to_classpath() {
    f="${PULSAR_HOME}/distribution/shell/build/classpath.txt"
    if [ ! -f "${f}" ]
    then
    (
      cd "${PULSAR_HOME}"
      ./gradlew :distribution:pulsar-shell-distribution:exportClasspath --no-configuration-cache -q 2> /dev/null
    )
    fi
    PULSAR_CLASSPATH=${CLASSPATH}:`cat "${f}"`
}

if [ -d "$PULSAR_HOME/lib" ]; then
    # Build the lib classpath as an explicit, C-locale-sorted list rather than the `lib/*` wildcard: the
    # JVM expands `lib/*` in filesystem readdir order, which varies across hosts/filesystems, so a prebuilt
    # CDS archive (which records the expanded classpath and matches it positionally) would silently mismatch
    # and no-op on a host whose order differs. A fixed order keeps the archive portable, and also makes
    # duplicate-class precedence deterministic instead of filesystem-dependent.
    PULSAR_CLASSPATH="$PULSAR_CLASSPATH:$(LC_ALL=C; set -- "$PULSAR_HOME"/lib/*.jar; IFS=:; printf '%s' "$*")"
else
    add_gradle_deps_to_classpath
fi

if [ -z "$PULSAR_CLIENT_CONF" ]; then
    PULSAR_CLIENT_CONF=$DEFAULT_CLIENT_CONF
fi
if [ -z "$PULSAR_LOG_CONF" ]; then
    PULSAR_LOG_CONF=$DEFAULT_LOG_CONF
fi

PULSAR_CLASSPATH="$PULSAR_JAR:$PULSAR_CLASSPATH:$PULSAR_EXTRA_CLASSPATH"
# Pass $PULSAR_LOG_CONF straight to log4j2 (resolved as a file), not conf-dir-on-classpath + basename:
# a non-empty dir ahead of the jars on the classpath blocks the AppCDS dump, and keeping the config off
# the classpath also lets a runtime PULSAR_LOG_CONF override still match the archive.
OPTS="$OPTS -Dlog4j.configurationFile=$PULSAR_LOG_CONF"
OPTS="-Djava.net.preferIPv4Stack=true $OPTS"
# Bridge java.util.logging (JUL) to Log4j2 so that JUL logs from third-party libraries
# (Jersey, gRPC, Guava, etc.) are bridged into the Log4j2 configuration (conf/log4j2.yaml)
OPTS="-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager $OPTS"
# Required to allow sun.misc.Unsafe on JDK 24 without warnings
# Also required for enabling unsafe memory access for Netty since 4.1.121.Final
if [[ $JAVA_MAJOR_VERSION -ge 23 ]]; then
  OPTS="--sun-misc-unsafe-memory-access=allow $OPTS"
fi
# Use compact object headers (JEP 519, https://openjdk.org/jeps/519), which shrink object headers from 12 to 8 bytes
# and so reduce heap usage and improve cache locality. They are a product feature since JDK 25 and the default from
# JDK 27 on (JEP 534, https://openjdk.org/jeps/534). The option is prepended so that the configured options can
# override it with -XX:-UseCompactObjectHeaders.
if [[ $JAVA_MAJOR_VERSION -eq 25 || $JAVA_MAJOR_VERSION -eq 26 ]]; then
  OPTS="-XX:+UseCompactObjectHeaders $OPTS"
fi

# Allow Netty to use reflection access
OPTS="$OPTS -Dio.netty.tryReflectionSetAccessible=true"
OPTS="$OPTS -Dorg.apache.pulsar.shade.io.netty.tryReflectionSetAccessible=true"

if [[ $JAVA_MAJOR_VERSION -gt 8 ]]; then
  OPTS="$OPTS --add-opens java.base/sun.net=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED"
  # Required by Pulsar client optimized checksum calculation on other than Linux x86_64 platforms
  # reflection access to java.util.zip.CRC32C
  OPTS="$OPTS --add-opens java.base/java.util.zip=ALL-UNNAMED"
fi

if [[ $JAVA_MAJOR_VERSION -ge 11 ]]; then
  # Required by Netty for optimized direct byte buffer access
  OPTS="$OPTS --add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/jdk.internal.misc=ALL-UNNAMED"
fi

if [[ $JAVA_MAJOR_VERSION -ge 24 ]]; then
  # Netty loads native libraries (epoll, io_uring, tcnative) via java.lang.System::loadLibrary,
  # which is a restricted method from Java 24 onwards. Without this the JVM prints a warning to
  # stderr on every invocation, and restricted methods will be blocked outright in a future
  # release. bin/pulsar already sets this for the server side.
  OPTS="$OPTS --enable-native-access=ALL-UNNAMED"
fi
# These two settings work together to ensure the Pulsar process exits immediately and predictably
# if it runs out of either Java heap memory or its internal off-heap memory,
# as these are unrecoverable errors that require a process restart to clear the faulty state and restore operation
OPTS="-XX:+ExitOnOutOfMemoryError -Dpulsar.allocator.exit_on_oom=true $OPTS"
# Netty tuning
# These settings are primarily used to modify the Netty allocator configuration,
# improving memory utilization and reducing the frequency of requesting off-heap memory from the OS
#
# Based on the netty source code, the allocator's default chunk size is calculated as:
# io.netty.allocator.pageSize (default: 8192) shifted left by
# io.netty.allocator.maxOrder (default: 9 after Netty 4.1.76.Final version).
# This equals 8192 * 2^9 = 4 MB：
# https://github.com/netty/netty/blob/4.1/buffer/src/main/java/io/netty/buffer/PooledByteBufAllocator.java#L105
#
# Allocations that are larger than chunk size are considered huge allocations and don't use the pool:
# https://github.com/netty/netty/blob/4.1/buffer/src/main/java/io/netty/buffer/PoolArena.java#L141-L142
#
# Currently, Pulsar defaults to a maximum single message size of 5 MB.
# Therefore, when frequently producing messages whose size exceeds the chunk size,
# Netty cannot utilize resources from the memory pool and must frequently allocate native memory.
# This can lead to increased physical memory fragmentation and higher reclamation costs.
# Thus, increasing io.netty.allocator.maxOrder to 10 to ensure that a single message is larger
# than chunk size (8MB) and can reuse Netty's memory pool.
OPTS="-Dio.netty.recycler.maxCapacityPerThread=4096 -Dio.netty.allocator.maxOrder=10 $OPTS"

# Disable Netty's leak detection by default, as bin/pulsar does, since it costs CPU on the hot paths;
# -Dio.netty.leakDetection.level in PULSAR_EXTRA_OPTS, which comes later on the command line, overrides it.
OPTS="-Dio.netty.leakDetection.level=disabled $OPTS"

OPTS="-cp $PULSAR_CLASSPATH $OPTS"

# AppCDS to cut CLI JVM startup (pulsar-admin/-client/-shell all source this). Only in an installed layout
# (a lib/ dir); a dev/source tree is skipped, so no cds/ is created there. Two archive files:
#  - pulsar-admin-static.jsa: a self-contained static archive (JDK base + app classes), e.g. pre-baked by
#    the Docker image; loaded directly when present, no base archive needed.
#  - pulsar-admin-dynamic.jsa: for an install whose JDK ships a base CDS archive (e.g. a full-JDK tarball).
#    Loaded if present; -XX:+AutoCreateSharedArchive (creates it on first run, self-heals after a JDK or
#    classpath change) is added only where the cds dir is writable -- against a read-only dir it aborts the
#    JVM (exit 1), hence the [ -w ] gate (set PULSAR_CDS_DIR to a writable path to enable it for a read-only
#    install). With no archive and no write access CDS is skipped. Separate static/dynamic names keep the
#    auto-created file from tripping the static branch. A JDK with no base archive is a benign no-op (exit 0).
# Runtime CDS messages are non-actionable (the environment just doesn't match the archive, so CDS no-ops and
# only the speedup is lost) and default to stdout, where they would corrupt `pulsar-admin ... | jq`, so
# silence them with -Xlog:cds=off; PULSAR_EXTRA_OPTS is appended after this and can re-enable it (-Xlog:cds).
# Opt out with PULSAR_CDS_ENABLED=false.
if [ "${PULSAR_CDS_ENABLED:-true}" = "true" ] && [ -d "$PULSAR_HOME/lib" ]; then
    PULSAR_CDS_DIR=${PULSAR_CDS_DIR:-"$PULSAR_HOME/cds"}
    if [ -f "$PULSAR_CDS_DIR/pulsar-admin-static.jsa" ]; then
        OPTS="$OPTS -XX:SharedArchiveFile=$PULSAR_CDS_DIR/pulsar-admin-static.jsa -Xlog:cds=off"
    elif [[ $JAVA_MAJOR_VERSION -ge 19 ]]; then
        mkdir -p "$PULSAR_CDS_DIR" 2>/dev/null || true
        PULSAR_CDS_DYNAMIC="$PULSAR_CDS_DIR/pulsar-admin-dynamic.jsa"
        if [ -f "$PULSAR_CDS_DYNAMIC" ]; then
            OPTS="$OPTS -XX:SharedArchiveFile=$PULSAR_CDS_DYNAMIC -Xlog:cds=off"
            [ -w "$PULSAR_CDS_DIR" ] && OPTS="$OPTS -XX:+AutoCreateSharedArchive"
        elif [ -w "$PULSAR_CDS_DIR" ]; then
            OPTS="$OPTS -XX:+AutoCreateSharedArchive -XX:SharedArchiveFile=$PULSAR_CDS_DYNAMIC -Xlog:cds=off"
        fi
    fi
fi

OPTS="$OPTS $PULSAR_EXTRA_OPTS"

# log directory & file
PULSAR_LOG_DIR=${PULSAR_LOG_DIR:-"$PULSAR_HOME/logs"}
PULSAR_LOG_APPENDER=${PULSAR_LOG_APPENDER:-"RoutingAppender"}
# PULSAR_LOG_CONSOLE_JSON_TEMPLATE is deprecated — use PULSAR_LOG_JSON_TEMPLATE
PULSAR_LOG_JSON_TEMPLATE=${PULSAR_LOG_JSON_TEMPLATE:-${PULSAR_LOG_CONSOLE_JSON_TEMPLATE:-"file:$PULSAR_HOME/conf/OtelLogLayout.json"}}
PULSAR_LOG_FORMAT=${PULSAR_LOG_FORMAT:-"text"}
PULSAR_LOG_LEVEL=${PULSAR_LOG_LEVEL:-"info"}
PULSAR_LOG_ROOT_LEVEL=${PULSAR_LOG_ROOT_LEVEL:-"${PULSAR_LOG_LEVEL}"}
PULSAR_ROUTING_APPENDER_DEFAULT=${PULSAR_ROUTING_APPENDER_DEFAULT:-"Console"}
PULSAR_LOG_IMMEDIATE_FLUSH="${PULSAR_LOG_IMMEDIATE_FLUSH:-"false"}"

#Configure log configuration system properties
OPTS="$OPTS -Dpulsar.log.appender=$PULSAR_LOG_APPENDER"
OPTS="$OPTS -Dpulsar.log.json.template=$PULSAR_LOG_JSON_TEMPLATE"
OPTS="$OPTS -Dpulsar.log.format=$PULSAR_LOG_FORMAT"
OPTS="$OPTS -Dpulsar.log.dir=$PULSAR_LOG_DIR"
OPTS="$OPTS -Dpulsar.log.level=$PULSAR_LOG_LEVEL"
OPTS="$OPTS -Dpulsar.log.root.level=$PULSAR_LOG_ROOT_LEVEL"
OPTS="$OPTS -Dpulsar.log.immediateFlush=$PULSAR_LOG_IMMEDIATE_FLUSH"
OPTS="$OPTS -Dpulsar.routing.appender.default=$PULSAR_ROUTING_APPENDER_DEFAULT"
