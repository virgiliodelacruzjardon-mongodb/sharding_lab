#!/usr/bin/env bash
# =============================================================================
# setup-sharded-lab.sh
# Laboratorio: sharded cluster MongoDB 9.0 con 3 shards en UN solo servidor
# Ubuntu 24.04 / 22.04 / 26.04 LTS · keyfile · systemd · hosts como localhost
#
# Uso:
#   sudo bash setup-sharded-lab.sh           # instala y configura todo
#   sudo bash setup-sharded-lab.sh upgrade   # sube un laboratorio 8.0/8.3 a 9.0
#   sudo bash setup-sharded-lab.sh status    # estado y versión de cada proceso
#   sudo bash setup-sharded-lab.sh stop      # apaga en orden
#   sudo bash setup-sharded-lab.sh start     # arranca en orden
#   sudo bash setup-sharded-lab.sh reset     # BORRA el laboratorio
#
# Variables opcionales (se ponen antes del comando):
#   EDITION=community|enterprise  edición (auto: la que ya esté instalada;
#                                 si no hay ninguna, community)
#   MONGO_VERSION=9.0.4  fija una versión 9.0.x concreta (si no, la más nueva)
#   MEMBERS=1|3          miembros por replica set (auto: 3 si hay >=15 GB RAM)
#   CACHE_GB=0.5         cache WiredTiger por mongod
#   SAMPLE_DATA=0        no cargar la colección de prueba labdb.clientes
#   UPGRADE_FCV=0        en "upgrade", dejar el FCV anterior (no activar 9.0)
#   ADMIN_PWD=...        password de clusterAdmin (si no, se pregunta)
#   SHARD_ADMIN_PWD=...  password de shardAdmin (si no, se pregunta)
# Ejemplo: sudo EDITION=enterprise MEMBERS=1 bash setup-sharded-lab.sh
# =============================================================================
set -euo pipefail

TARGET_SERIES=9.0
CONF_DIR=/etc/mongodb-lab
DATA_DIR=/data/mongo
LOG_DIR=/var/log/mongodb
UNIT_DIR=/etc/systemd/system
KEYFILE=$CONF_DIR/keyfile
STATE=$CONF_DIR/lab.env
KEYRING=/usr/share/keyrings/mongodb-server-9.gpg
MONGOS_PORT=27017
ADMIN_USER=clusterAdmin
SHARD_ADMIN_USER=shardAdmin
SAMPLE_DATA=${SAMPLE_DATA:-1}

COMPONENTS=(cfg sh1 sh2 sh3)
SHARDS=(sh1 sh2 sh3)
declare -A RS=( [cfg]=cfgRS [sh1]=shard1RS [sh2]=shard2RS [sh3]=shard3RS )
declare -A ROLE=( [cfg]=configsvr [sh1]=shardsvr [sh2]=shardsvr [sh3]=shardsvr )
declare -A BASE=( [cfg]=27100 [sh1]=27200 [sh2]=27300 [sh3]=27400 )

# ----------------------------------------------------------------- utilidades
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Ejecuta con sudo: sudo bash $0 ${1:-}"; }

member_names() { if [[ $MEMBERS == 3 ]]; then echo "a b c"; else echo "a"; fi; }
idx_of()  { case $1 in a) echo 1 ;; b) echo 2 ;; c) echo 3 ;; esac; }
port_of() { local g=${1%-*} m=${1##*-}; echo $(( ${BASE[$g]} + $(idx_of "$m") )); }

instances_of()  { local g=$1 m; for m in $(member_names); do echo "$g-$m"; done; }
all_instances() { local g; for g in "${COMPONENTS[@]}"; do instances_of "$g"; done; }
units_of()      { local i; for i in $(instances_of "$1"); do echo "mongod-lab@$i"; done; }
shard_units()   { local g; for g in "${SHARDS[@]}"; do units_of "$g"; done; }

enabled_instances_of() { # solo las instancias con servicio habilitado
  local i
  for i in $(instances_of "$1"); do
    if systemctl is-enabled --quiet "mongod-lab@$i" 2>/dev/null; then echo "$i"; fi
  done
}

hosts_of() { # localhost:27201,localhost:27202,...
  local g=$1 out="" i
  for i in $(instances_of "$g"); do out+="${out:+,}localhost:$(port_of "$i")"; done
  echo "$out"
}
members_js() { # { _id: 0, host: 'localhost:27201' }, ...
  local g=$1 out="" n=0 i
  for i in $(instances_of "$g"); do
    out+="${out:+, }{ _id: $n, host: 'localhost:$(port_of "$i")' }"; n=$((n + 1))
  done
  echo "$out"
}

msh() { mongosh --quiet "$@"; }

wait_ping() { # espera a que responda el proceso en un puerto
  local port=$1 timeout=${2:-90} t
  for ((t = 0; t < timeout; t++)); do
    if msh --port "$port" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "Nada responde en el puerto $port. Revisa: sudo tail -n 50 $LOG_DIR/*.log"
}

wait_primary() { # espera a que el replica set tenga PRIMARY
  local port=$1
  msh --port "$port" --eval "
    let t = 0;
    while (db.hello().primary == null) { if (++t > 120) quit(1); sleep(1000); }
    print('    PRIMARY: ' + db.hello().primary);" \
    || die "El replica set del puerto $port no eligió PRIMARY en 120 s."
}

load_state() {
  [[ -f $STATE ]] || die "No hay laboratorio configurado ($STATE no existe). Ejecuta: sudo bash $0"
  # shellcheck disable=SC1090
  source "$STATE"
}

AUTH_JS="db.getSiblingDB('admin').auth('$ADMIN_USER', process.env.ADMIN_PWD);"
mongos_js() { msh --port "$MONGOS_PORT" --eval "$AUTH_JS $1"; }

show_fcv() { # el FCV se lee en el config server (el mongos no lo reporta)
  msh --port "$(port_of cfg-a)" --eval "$AUTH_JS
    print('    FCV del clúster: ' +
      db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version);" \
    || warn "No se pudo leer el FCV en el puerto $(port_of cfg-a)."
}

# ------------------------------------------------------- versión y paquetes
installed_version() { # v9.0.4, o vacío si no hay mongod
  if command -v mongod >/dev/null 2>&1; then
    mongod --version 2>/dev/null | awk '/db version/ {print $3; exit}'
  fi
}
major_minor() { local v=${1#v}; [[ -n $v ]] && echo "${v%.*}" || true; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

detect_edition() {
  local found=""
  if pkg_installed mongodb-enterprise-server; then found=enterprise
  elif pkg_installed mongodb-org-server; then found=community; fi
  EDITION=${EDITION:-${found:-community}}
  [[ $EDITION == community || $EDITION == enterprise ]] || die "EDITION debe ser community o enterprise."
  if [[ -n $found && $found != "$EDITION" ]]; then
    die "Ya está instalada la edición $found. Este script no cambia de edición: usa EDITION=$found o desinstala la otra primero."
  fi
}

packages() { # paquetes de la edición, con versión si MONGO_VERSION está definida
  local p=mongodb-org v=${MONGO_VERSION:+=$MONGO_VERSION} n
  [[ $EDITION == enterprise ]] && p=mongodb-enterprise
  for n in "$p" "$p-database" "$p-server" "$p-mongos" "$p-tools"; do echo "$n$v"; done
  echo mongodb-mongosh
}

install_packages() {
  . /etc/os-release
  local code=${VERSION_CODENAME:-} arch host path list f
  case $code in
    noble|jammy|resolute) ;;
    *) die "MongoDB $TARGET_SERIES se instala aquí solo en Ubuntu 24.04, 22.04 o 26.04 (detectado: ${PRETTY_NAME:-desconocido})." ;;
  esac
  arch=$(dpkg --print-architecture)
  [[ $arch == amd64 || $arch == arm64 ]] || die "Arquitectura no soportada: $arch"
  if [[ $EDITION == enterprise ]]; then host=repo.mongodb.com; path=mongodb-enterprise
  else host=repo.mongodb.org; path=mongodb-org; fi
  list=/etc/apt/sources.list.d/$path-$TARGET_SERIES.list

  log "Configurando el repositorio oficial de MongoDB $EDITION $TARGET_SERIES ($code)"
  for f in /etc/apt/sources.list.d/mongodb-org-*.list /etc/apt/sources.list.d/mongodb-enterprise-*.list; do
    [[ -e $f && $f != "$list" ]] || continue
    mv "$f" "$f.disabled"; info "repositorio anterior desactivado: $f"
  done
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg curl ca-certificates
  curl -fsSL https://pgp.mongodb.com/server-9.asc | gpg --dearmor --yes -o "$KEYRING"
  echo "deb [ arch=amd64,arm64 signed-by=$KEYRING ] https://$host/apt/ubuntu $code/$path/$TARGET_SERIES multiverse" > "$list"
  apt-get update -qq

  log "Instalando paquetes de MongoDB $EDITION ${MONGO_VERSION:-$TARGET_SERIES (última)}"
  # shellcheck disable=SC2046
  apt-mark unhold $(packages | sed 's/=.*//') >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages --allow-downgrades $(packages)
}

check_version() {
  local ver; ver=$(installed_version)
  [[ $(major_minor "$ver") == "$TARGET_SERIES" ]] || die "Tras instalar se esperaba la serie $TARGET_SERIES y se encontró ${ver:-nada}."
  command -v mongos >/dev/null && command -v mongosh >/dev/null || die "Faltan mongos o mongosh tras la instalación."
  info "mongod $ver · mongosh $(mongosh --version)"
}

# ------------------------------------------------------------------- pasos
choose_topology() {
  local mem_gb
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if [[ -z ${MEMBERS:-} ]]; then
    if (( mem_gb >= 15 )); then MEMBERS=3; else MEMBERS=1; fi
  fi
  [[ $MEMBERS == 1 || $MEMBERS == 3 ]] || die "MEMBERS debe ser 1 o 3."
  if [[ -z ${CACHE_GB:-} ]]; then
    if [[ $MEMBERS == 3 ]] && (( mem_gb < 15 )); then CACHE_GB=0.25; else CACHE_GB=0.5; fi
  fi
  local n=$(( ${#COMPONENTS[@]} * MEMBERS ))
  local need
  need=$(awk -v n="$n" -v c="$CACHE_GB" 'BEGIN { printf "%.1f", n * (c + 0.4) + 0.5 }')
  log "Topología: 3 shards + config server, $MEMBERS miembro(s) por replica set"
  info "RAM total: ~${mem_gb} GB · $n mongod + 1 mongos · cacheSizeGB=$CACHE_GB · uso estimado ~${need} GB"
  if awk -v a="$mem_gb" -v b="$need" 'BEGIN { exit !(a < b + 1) }'; then
    warn "La RAM es justa para esta topología. Si el kernel termina procesos, usa MEMBERS=1 o un CACHE_GB menor (p. ej. 0.25)."
  fi
}

preflight() {
  log "Verificando el sistema"
  . /etc/os-release
  info "Sistema: ${PRETTY_NAME:-desconocido}"
  if [[ -d $DATA_DIR/cfg-a && -n $(ls -A "$DATA_DIR/cfg-a" 2>/dev/null) ]]; then
    die "Ya existe un laboratorio en $DATA_DIR. Para subirlo a $TARGET_SERIES: sudo bash $0 upgrade · Para empezar de cero: sudo bash $0 reset"
  fi
}

install_mongodb() {
  detect_edition
  local ver; ver=$(installed_version)
  if [[ $(major_minor "$ver") == "$TARGET_SERIES" ]] && command -v mongos >/dev/null && command -v mongosh >/dev/null; then
    log "MongoDB $EDITION $ver ya instalado"
    return
  fi
  if [[ -n $ver ]]; then
    log "Se encontró MongoDB $ver ($EDITION); se actualizarán los paquetes a $TARGET_SERIES"
    warn "El servicio mongod por defecto (/var/lib/mongodb) no se usa en este laboratorio y queda desactivado. Si tiene datos de otra versión, súbelo con la guía oficial antes de volver a usarlo."
  fi
  install_packages
  check_version
}

free_default_port() {
  log "Desactivando el servicio mongod por defecto (libera el 27017; no borra datos)"
  systemctl disable --now mongod.service >/dev/null 2>&1 || true
  local p i busy=0
  for p in "$MONGOS_PORT" $(for i in $(all_instances); do port_of "$i"; done); do
    if ss -ltnH "sport = :$p" | grep -q .; then warn "Puerto $p ocupado"; busy=1; fi
  done
  (( busy == 0 )) || die "Libera los puertos ocupados (sudo ss -ltnp) y vuelve a ejecutar."
}

ask_pwd() { # ask_pwd VARIABLE "etiqueta"  (contraseña nueva, con confirmación)
  local __var=$1 label=$2 p1 p2
  [[ -n ${!__var:-} ]] && return 0
  while true; do
    read -rsp "    Contraseña para $label: " p1; echo
    read -rsp "    Confírmala: " p2; echo
    [[ $p1 == "$p2" ]] || { warn "No coinciden, intenta de nuevo."; continue; }
    (( ${#p1} >= 8 )) || { warn "Usa al menos 8 caracteres."; continue; }
    printf -v "$__var" '%s' "$p1"; break
  done
}

ask_existing_pwd() { # ask_existing_pwd VARIABLE "etiqueta"  (contraseña ya creada)
  local __var=$1 label=$2 p
  [[ -n ${!__var:-} ]] && return 0
  read -rsp "    Contraseña actual de $label: " p; echo
  printf -v "$__var" '%s' "$p"
}

ask_passwords() {
  log "Contraseñas (no se muestran ni se guardan en disco)"
  ask_pwd ADMIN_PWD "$ADMIN_USER (administrador del clúster, entra por el mongos)"
  ask_pwd SHARD_ADMIN_PWD "$SHARD_ADMIN_USER (administrador local de cada shard)"
  export ADMIN_PWD SHARD_ADMIN_PWD   # mongosh las lee con process.env
}

write_files() {
  log "Creando keyfile, configuraciones y servicios systemd"
  id mongodb >/dev/null 2>&1 || die "No existe el usuario 'mongodb' (debería crearlo el paquete de MongoDB)."
  mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
  if [[ ! -f $KEYFILE ]]; then openssl rand -base64 756 > "$KEYFILE"; fi
  chmod 400 "$KEYFILE"; chown mongodb:mongodb "$KEYFILE"

  local g i
  for g in "${COMPONENTS[@]}"; do
    for i in $(instances_of "$g"); do
      mkdir -p "$DATA_DIR/$i"
      cat > "$CONF_DIR/$i.conf" <<CONF
storage:
  dbPath: $DATA_DIR/$i
  wiredTiger:
    engineConfig:
      cacheSizeGB: $CACHE_GB
systemLog:
  destination: file
  path: $LOG_DIR/$i.log
  logAppend: true
net:
  port: $(port_of "$i")
  bindIp: 127.0.0.1
replication:
  replSetName: ${RS[$g]}
sharding:
  clusterRole: ${ROLE[$g]}
security:
  keyFile: $KEYFILE
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
CONF
      info "$i -> puerto $(port_of "$i") (${RS[$g]})"
    done
  done

  cat > "$CONF_DIR/mongos.conf" <<CONF
sharding:
  configDB: cfgRS/$(hosts_of cfg)
systemLog:
  destination: file
  path: $LOG_DIR/mongos.log
  logAppend: true
net:
  port: $MONGOS_PORT
  bindIp: 127.0.0.1
security:
  keyFile: $KEYFILE
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
CONF
  info "mongos -> puerto $MONGOS_PORT"
  chown -R mongodb:mongodb "$DATA_DIR" "$LOG_DIR"

  cat > "$UNIT_DIR/mongod-lab@.service" <<'UNIT'
[Unit]
Description=MongoDB lab mongod %i
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongodb-lab/%i.conf
Restart=on-failure
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitMEMLOCK=infinity
LimitNOFILE=64000
LimitNPROC=64000
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

  cat > "$UNIT_DIR/mongos-lab.service" <<UNIT
[Unit]
Description=MongoDB lab mongos router
After=network-online.target
After=$(units_of cfg | sed 's/$/.service/' | tr '\n' ' ')

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongos --config $CONF_DIR/mongos.conf
Restart=on-failure
LimitNOFILE=64000
LimitNPROC=64000

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  printf 'MEMBERS=%s\nCACHE_GB=%s\n' "$MEMBERS" "$CACHE_GB" > "$STATE"
}

init_rs() { # init_rs componente [extra_js]
  local g=$1 extra=${2:-} first; first=$(port_of "${g}-a")
  msh --port "$first" --eval "rs.initiate({ _id: '${RS[$g]}', ${extra} members: [ $(members_js "$g") ] }).ok" >/dev/null \
    || die "Falló rs.initiate() en ${RS[$g]}"
  wait_primary "$first"
}

setup_config_servers() {
  log "Config server replica set (cfgRS)"
  # shellcheck disable=SC2046
  systemctl enable --now $(units_of cfg) >/dev/null
  local i; for i in $(instances_of cfg); do wait_ping "$(port_of "$i")"; done
  init_rs cfg "configsvr: true,"
}

setup_shards() {
  local g i
  # shellcheck disable=SC2046
  systemctl enable --now $(shard_units) >/dev/null
  for g in "${SHARDS[@]}"; do
    log "Shard ${RS[$g]}"
    for i in $(instances_of "$g"); do wait_ping "$(port_of "$i")"; done
    init_rs "$g"
    msh "mongodb://$(hosts_of "$g")/admin?replicaSet=${RS[$g]}" --eval "
      db.getSiblingDB('admin').createUser({
        user: '$SHARD_ADMIN_USER', pwd: process.env.SHARD_ADMIN_PWD,
        roles: [ { role: 'userAdminAnyDatabase', db: 'admin' },
                 { role: 'clusterAdmin', db: 'admin' } ] });
      print('    usuario local $SHARD_ADMIN_USER creado');" \
      || die "No se pudo crear $SHARD_ADMIN_USER en ${RS[$g]}"
  done
}

setup_mongos() {
  log "Router mongos y administrador del clúster"
  systemctl enable --now mongos-lab >/dev/null
  wait_ping "$MONGOS_PORT" 180
  msh --port "$MONGOS_PORT" --eval "
    db.getSiblingDB('admin').createUser({
      user: '$ADMIN_USER', pwd: process.env.ADMIN_PWD,
      roles: [ { role: 'userAdminAnyDatabase', db: 'admin' },
               { role: 'clusterAdmin', db: 'admin' },
               { role: 'readWriteAnyDatabase', db: 'admin' } ] });
    print('    usuario $ADMIN_USER creado');" \
    || die "No se pudo crear $ADMIN_USER en el mongos"
}

add_shards() {
  log "Agregando los 3 shards al clúster"
  local g js="$AUTH_JS"
  for g in "${SHARDS[@]}"; do
    js+=" sh.addShard('${RS[$g]}/$(hosts_of "$g")'); print('    agregado ${RS[$g]}');"
  done
  js+=" const s = db.adminCommand({ listShards: 1 }).shards;
        s.forEach(x => print('    ' + x._id + '  ' + x.host));
        if (s.length !== 3) quit(1);"
  msh --port "$MONGOS_PORT" --eval "$js" || die "No quedaron registrados los 3 shards (revisa $LOG_DIR/mongos.log)"
}

load_sample_data() {
  [[ $SAMPLE_DATA == 1 ]] || return 0
  log "Prueba: labdb.clientes con shard key hashed y 30,000 documentos"
  msh --port "$MONGOS_PORT" --eval "$AUTH_JS
    const d = db.getSiblingDB('labdb');
    sh.shardCollection('labdb.clientes', { _id: 'hashed' });
    const regiones = ['norte', 'centro', 'sur'];
    d.clientes.insertMany(Array.from({ length: 30000 }, (_, i) =>
      ({ _id: i, nombre: 'cliente' + i, region: regiones[i % 3] })));
    print('    documentos: ' + d.clientes.countDocuments());
    d.clientes.getShardDistribution();" || warn "La carga de prueba falló; el clúster sigue configurado."
}

start_ordered() { # config servers -> shards -> mongos (solo servicios habilitados)
  log "Arrancando: config servers -> shards -> mongos"
  local g i inst
  for g in "${COMPONENTS[@]}"; do
    inst=$(enabled_instances_of "$g")
    if [[ -z $inst ]]; then
      [[ $g == cfg ]] && die "No hay config servers habilitados."
      info "${RS[$g]}: sin servicios habilitados (¿shard eliminado?), se omite"
      continue
    fi
    # shellcheck disable=SC2046
    systemctl start $(for i in $inst; do echo "mongod-lab@$i"; done)
    for i in $inst; do wait_ping "$(port_of "$i")"; done
    info "${RS[$g]}:"
    wait_primary "$(port_of "${inst%%$'\n'*}")"
  done
  systemctl start mongos-lab
  wait_ping "$MONGOS_PORT" 180
  info "mongos listo en el puerto $MONGOS_PORT"
}

summary() {
  log "Listo: sharded cluster con 3 shards en MongoDB $EDITION $(installed_version)"
  cat <<TXT
    Conectarte:  mongosh --port $MONGOS_PORT -u $ADMIN_USER -p --authenticationDatabase admin
    Estado:      sudo bash $0 status
    Apagar/arrancar en orden:  sudo bash $0 stop | start
    Configs: $CONF_DIR   Datos: $DATA_DIR   Logs: $LOG_DIR
    Shard directo (solo mantenimiento, usuario $SHARD_ADMIN_USER):
      mongosh "mongodb://$(hosts_of sh1)/admin?replicaSet=shard1RS" -u $SHARD_ADMIN_USER -p
TXT
}

# --------------------------------------------------------------- comandos
cmd_setup() {
  need_root
  choose_topology
  preflight
  install_mongodb
  free_default_port
  ask_passwords
  write_files
  setup_config_servers
  setup_shards
  setup_mongos
  add_shards
  load_sample_data
  summary
}

cmd_upgrade() { # 8.0 / 8.3 -> 9.0, siguiendo el orden de la guía oficial
  need_root upgrade; load_state
  detect_edition
  local ver mm; ver=$(installed_version); mm=$(major_minor "$ver")
  log "Actualizar el laboratorio a MongoDB $TARGET_SERIES (instalado: ${ver:-ninguno}, edición: $EDITION)"
  case $mm in
    "$TARGET_SERIES") info "Los binarios ya son $TARGET_SERIES; solo se revisa el FCV." ;;
    8.0|8.3) ;;
    *) die "A $TARGET_SERIES solo se sube desde 8.0 u 8.3 (tienes ${ver:-nada}). Sube primero a 8.0, o recrea el laboratorio: sudo bash $0 reset && sudo bash $0" ;;
  esac

  ask_existing_pwd ADMIN_PWD "$ADMIN_USER"
  export ADMIN_PWD
  start_ordered
  mongos_js "print('    autenticado como $ADMIN_USER')" >/dev/null || die "No se pudo autenticar como $ADMIN_USER en el mongos."
  show_fcv

  log "Revisando que ningún shard se esté drenando"
  mongos_js "
    const d = db.getSiblingDB('config').shards.find({ draining: true }, { _id: 1 }).toArray().map(x => x._id);
    if (d.length) { print('    shards en drenado: ' + d.join(', ')); quit(2); }
    print('    ninguno');" \
    || die "Hay un shard en proceso de eliminación. Termínalo antes de actualizar (en 8.0: db.adminCommand({ removeShard: '<shard>' }) hasta state: 'completed')."

  if [[ $mm != "$TARGET_SERIES" ]]; then
    log "Requisito: FCV $mm en todo el clúster"
    mongos_js "db.adminCommand({ setFeatureCompatibilityVersion: '$mm', confirm: true }); print('    FCV fijado en $mm');" \
      || die "No se pudo fijar el FCV en $mm."
    log "Deteniendo el balancer"
    mongos_js "sh.stopBalancer(); print('    balancer activo: ' + sh.getBalancerState());" || die "No se pudo detener el balancer."
    # En un solo servidor todos los procesos usan el mismo binario: se apaga todo,
    # se cambian los paquetes y se arranca en el orden config -> shards -> mongos.
    cmd_stop
    install_packages
    check_version
    start_ordered
  fi

  if [[ ${UPGRADE_FCV:-1} == 1 ]]; then
    log "Activando las funciones de $TARGET_SERIES (FCV $TARGET_SERIES)"
    info "Puede tardar: MongoDB pasa metadatos del config server a los shards."
    mongos_js "db.adminCommand({ setFeatureCompatibilityVersion: '$TARGET_SERIES', confirm: true }); print('    FCV fijado en $TARGET_SERIES');" \
      || die "Falló setFeatureCompatibilityVersion $TARGET_SERIES (revisa $LOG_DIR/mongos.log)."
  else
    warn "El FCV se queda como estaba. Para activarlo después: db.adminCommand({ setFeatureCompatibilityVersion: '$TARGET_SERIES', confirm: true })"
  fi

  mongos_js "sh.startBalancer(); print('    balancer activo: ' + sh.getBalancerState());" || warn "Activa el balancer a mano: sh.startBalancer()"
  show_fcv
  log "Laboratorio en MongoDB $EDITION $(installed_version)"
  cmd_status
}

cmd_start() {
  need_root start; load_state
  start_ordered
  cmd_status
}

cmd_stop() {
  need_root stop; load_state
  log "Apagando: mongos -> shards -> config servers"
  systemctl stop mongos-lab || true
  # shellcheck disable=SC2046
  systemctl stop $(shard_units) || true
  # shellcheck disable=SC2046
  systemctl stop $(units_of cfg) || true
  info "Detenido."
}

cmd_status() {
  load_state
  log "Estado del laboratorio ($MEMBERS miembro(s) por replica set · binarios $(installed_version))"
  local i p st ping
  printf '    %-10s %-7s %-10s %s\n' "INSTANCIA" "PUERTO" "SERVICIO" "PING"
  for i in $(all_instances) mongos; do
    if [[ $i == mongos ]]; then p=$MONGOS_PORT; st=$(systemctl is-active mongos-lab || true)
    else p=$(port_of "$i"); st=$(systemctl is-active "mongod-lab@$i" || true); fi
    if msh --port "$p" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then ping=ok; else ping=--; fi
    printf '    %-10s %-7s %-10s %s\n' "$i" "$p" "$st" "$ping"
  done
}

cmd_reset() {
  need_root reset
  warn "Esto BORRA datos, usuarios, configuraciones y servicios del laboratorio (no desinstala MongoDB)."
  if [[ ${FORCE:-0} != 1 ]]; then
    read -rp "    Escribe BORRAR para continuar: " ans
    [[ $ans == BORRAR ]] || die "Cancelado."
  fi
  systemctl disable --now mongos-lab >/dev/null 2>&1 || true
  local units
  units=$(systemctl list-units --all --plain --no-legend 'mongod-lab@*' | awk '{print $1}')
  # shellcheck disable=SC2086
  [[ -z $units ]] || systemctl disable --now $units >/dev/null 2>&1 || true
  rm -rf "${DATA_DIR:?}"/cfg-* "${DATA_DIR:?}"/sh[123]-*
  rm -f "$LOG_DIR"/cfg-*.log "$LOG_DIR"/sh[123]-*.log "$LOG_DIR"/mongos.log
  rm -rf "${CONF_DIR:?}"
  rm -f "$UNIT_DIR/mongod-lab@.service" "$UNIT_DIR/mongos-lab.service"
  systemctl daemon-reload
  log "Laboratorio eliminado. Para crearlo de nuevo: sudo bash $0"
}

usage() { sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case ${1:-setup} in
  setup)   cmd_setup ;;
  upgrade) cmd_upgrade ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  reset)   cmd_reset ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
