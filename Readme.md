````markdown
# CPUCheck Helm Chart + GitHub Pages Helm Repo (Complete Start → End + Uninstall)

This README explains how to:
1) Create a Helm chart for CPU node usage checking + email alert (CronJob)
2) Install and manually test it in Kubernetes
3) Package and publish the chart as a Helm repository using GitHub Pages
4) Clone and test installation from the hosted repo
5) Uninstall and clean up after testing

---

## 0) Prerequisites

### Tools
- Helm: `helm version`
- Kubectl: `kubectl version --client`
- Access to a Kubernetes cluster (AKS/EKS/etc.) with kubeconfig set

### Cluster Requirement (IMPORTANT)
The script uses:
```bash
kubectl top nodes
````

So the cluster needs **metrics-server**.

Check:

```bash
kubectl get apiservices | grep metrics
```

---

## 1) Directory Structure Used

We will work under:

```
~/Emplay/aks/
```

Final folder structure:

```
~/Emplay/aks/
  cpucheck/                # Helm chart source
  helm-repo/               # packaged chart + index.yaml
  docs/                    # GitHub Pages folder (serves index.yaml)
```

---

## 2) Create Helm Chart (from scratch)

📍 Location:

```bash
cd ~/Emplay/aks
```

Create chart:

```bash
helm create cpucheck
cd cpucheck
rm -rf templates/*
mkdir -p scripts
```

Check:

```bash
ls
# charts  Chart.yaml  scripts  templates  values.yaml
```

---

## 3) Add Scripts

📍 Location:

```bash
cd ~/Emplay/aks/cpucheck
```

### 3.1 scripts/utils.sh

Create:

```bash
nano scripts/utils.sh
```

Paste:

```bash
#!/bin/bash
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/cpucheck_$(date '+%Y-%m-%d').log"
}

retry_with_config() {
  local cmd=$1 retries=$2 interval=$3 count=0
  until $cmd; do
    count=$((count+1))
    [ $count -ge $retries ] && return 1
    log "DEBUG" "Retry $count/$retries failed, sleeping $interval"
    sleep $interval
  done
  return 0
}

can_alert() {
  local cooldown=$1 file=/opt/state/last_alert now=$(date +%s)
  if [ -f $file ]; then
    last=$(<$file)
    if (( last + cooldown > now )); then
      remain=$(( last + cooldown - now ))
      log "INFO" "Cooldown active, skipping alert (wait ${remain}s more)"
      return 1
    fi
  fi
  echo $now > $file
  return 0
}

send_email() {
  local node=$1
  local usage=$2

  # Read SMTP password from mounted Secret file
  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX High CPU Alert on $node"
    BODY="ALERT: Node $node CPU=$usage% (Threshold=$CPU_THRESHOLD%)"

    RCPT_ARGS=()
    for rcpt in $(echo $EMAIL_TO | tr ',' ' '); do
      RCPT_ARGS+=( --mail-rcpt "$rcpt" )
    done

    curl --silent --show-error --fail \
      --url "smtp://$SMTP_HOST:$SMTP_PORT" \
      --ssl-reqd \
      --mail-from "$EMAIL_FROM" \
      "${RCPT_ARGS[@]}" \
      --user "$SMTP_USERNAME:$SMTP_PASSWORD" \
      -T <(echo -e "From: $EMAIL_FROM\nTo: $EMAIL_TO\nSubject: $SUBJECT\n\n$BODY")
  fi
}
```

### 3.2 scripts/checkcpu.sh

Create:

```bash
nano scripts/checkcpu.sh
```

Paste:

```bash
#!/bin/bash
source /opt/config/config.env
source /opt/utils/utils.sh

# cleanup old logs
find "$LOG_DIR" -type f -name "cpucheck_*.log" -mtime +7 -delete || true

check_cpu() {
  log "DEBUG" "Checking CPU usage across all nodes..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  while read -r node cpu mem; do
    usage=${cpu%\%}
    total_count=$((total_count+1))

    if [ "$usage" -ge "$CPU_THRESHOLD" ]; then
      log "WARNING" "Node $node is above threshold: ${usage}%"
      alert=1
    else
      log "INFO" "Node $node is healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $3, $5}')

  echo "$max_node" > /opt/state/max_node
  echo "$max_usage" > /opt/state/max_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy. Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High CPU detected. Worst=$max_usage% on $max_node"
  fi
  return $alert
}

if retry_with_config check_cpu $RETRY_COUNT $RETRY_INTERVAL; then
  exit 0
else
  if can_alert $COOLDOWN_PERIOD; then
    NODE=$(cat /opt/state/max_node)
    USAGE=$(cat /opt/state/max_usage)
    send_email "$NODE" "$USAGE"
    log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
  fi
  exit 0
fi
```

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

---

## 4) Configure values.yaml

📍 Location:

```bash
cd ~/Emplay/aks/cpucheck
```

Edit:

```bash
nano values.yaml
```

Paste:

```yaml
schedule: "*/5 * * * *"

image:
  repository: python
  tag: 3.11-slim
  pullPolicy: IfNotPresent

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "7200"
  CPU_THRESHOLD: "60"
  LOG_DIR: "/opt/logs"
  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][CPU]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""

persistence:
  state:
    name: cpucheck-state-pvc
    size: 5Mi
  logs:
    name: self-heal-logs-pvc
    size: 50Mi

serviceAccount:
  name: cpucheck-sa
```

---

## 5) Create Helm Templates (Kubernetes resources)

✅ IMPORTANT: Use release namespace in all manifests:

```yaml
namespace: {{ .Release.Namespace }}
```

📍 Location:

```bash
cd ~/Emplay/aks/cpucheck
```

### 5.1 templates/configmap.yaml

```bash
nano templates/configmap.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cpucheck-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    CPU_THRESHOLD={{ .Values.config.CPU_THRESHOLD }}
    LOG_DIR={{ .Values.config.LOG_DIR }}
    EMAIL_ENABLED={{ .Values.config.EMAIL_ENABLED }}
    EMAIL_SUBJECT_PREFIX="{{ .Values.config.EMAIL_SUBJECT_PREFIX }}"
    EMAIL_FROM={{ .Values.config.EMAIL_FROM }}
    EMAIL_TO={{ .Values.config.EMAIL_TO }}
    SMTP_HOST={{ .Values.config.SMTP_HOST }}
    SMTP_PORT={{ .Values.config.SMTP_PORT }}
    SMTP_USERNAME={{ .Values.config.SMTP_USERNAME }}
    SMTP_PASSWORD_FILE=/opt/secret/SMTP_PASSWORD

  utils.sh: |
{{ .Files.Get "scripts/utils.sh" | indent 4 }}

  checkcpu.sh: |
{{ .Files.Get "scripts/checkcpu.sh" | indent 4 }}
```

### 5.2 templates/secret.yaml

```bash
nano templates/secret.yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cpucheck-smtp-secret
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}
```

### 5.3 templates/pvc.yaml

```bash
nano templates/pvc.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.persistence.state.name }}
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.persistence.state.size }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.persistence.logs.name }}
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.persistence.logs.size }}
```

### 5.4 templates/serviceaccount.yaml

```bash
nano templates/serviceaccount.yaml
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name }}
  namespace: {{ .Release.Namespace }}
```

### 5.5 templates/rbac.yaml

```bash
nano templates/rbac.yaml
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cpucheck-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get","list"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes"]
  verbs: ["get","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cpucheck-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cpucheck-role
subjects:
- kind: ServiceAccount
  name: {{ .Values.serviceAccount.name }}
  namespace: {{ .Release.Namespace }}
```

### 5.6 templates/cronjob.yaml

```bash
nano templates/cronjob.yaml
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cpucheck-cron
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.schedule | quote }}
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 120
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: {{ .Values.serviceAccount.name }}
          restartPolicy: OnFailure
          containers:
          - name: cpucheck
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            imagePullPolicy: {{ .Values.image.pullPolicy }}
            command: ["/bin/bash", "-c"]
            args:
              - |
                set -e
                apt-get update && \
                apt-get install -y curl ca-certificates && \
                curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                bash /opt/scripts/checkcpu.sh
            volumeMounts:
            - name: scripts
              subPath: checkcpu.sh
              mountPath: /opt/scripts/checkcpu.sh
            - name: scripts
              subPath: config.env
              mountPath: /opt/config/config.env
            - name: scripts
              subPath: utils.sh
              mountPath: /opt/utils/utils.sh
            - name: state
              mountPath: /opt/state
            - name: logs
              mountPath: /opt/logs
            - name: smtpsecret
              mountPath: /opt/secret
              readOnly: true
          volumes:
          - name: scripts
            configMap:
              name: cpucheck-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ .Values.persistence.state.name }}
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.persistence.logs.name }}
          - name: smtpsecret
            secret:
              secretName: cpucheck-smtp-secret
```

---

## 6) Install and Test Locally

📍 Location:

```bash
cd ~/Emplay/aks/cpucheck
```

Lint:

```bash
helm lint .
```

Install (enter SMTP password here):

```bash
helm install cpucheck . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default
kubectl get pvc -n default
```

Manual test (run once without waiting schedule):

```bash
kubectl create job --from=cronjob/cpucheck-cron cpucheck-manual -n default
kubectl logs -n default job/cpucheck-manual --follow
```

---

## 7) Package Chart for Helm Repo (GitHub Pages)

📍 Location:

```bash
cd ~/Emplay/aks
```

Commands:

```bash
mkdir -p helm-repo docs
helm package cpucheck -d helm-repo
helm repo index helm-repo --url https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
cp -r helm-repo/* docs/
```

Check:

```bash
ls docs
# cpucheck-0.1.0.tgz  index.yaml
```

---

## 8) GitHub Repo Creation + Push (Two Options)

### Option A: Create Repo in Browser then push

1. GitHub → New repository
2. Owner: `<GITHUB_USERNAME>`
3. Repo: `<REPO_NAME>` (example: `cpucheck-helm-repo`)
4. Public → Create

📍 Location:

```bash
cd ~/Emplay/aks
```

Push:

```bash
git init
git add .
git commit -m "Publish cpucheck helm repo"
git branch -M main
git remote add origin https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
git push -u origin main
```

### Option B: Create Repo from Terminal (gh) then push

Install gh and login:

```bash
gh --version || (sudo apt update && sudo apt install -y gh)
gh auth login
gh auth status
```

Create repo + push:

```bash
cd ~/Emplay/aks
git init
git add .
git commit -m "Publish cpucheck helm repo"
git branch -M main

gh repo create <REPO_NAME> --public --source=. --remote=origin --push
```

If remote origin already exists:

```bash
git remote set-url origin https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
git push -u origin main
```

---

## 9) Enable GitHub Pages (Two Options)

### Option A: Browser

Repo → Settings → Pages:

* Source: Deploy from branch
* Branch: `main`
* Folder: `/docs`

### Option B: Terminal (gh API)

Create pages:

```bash
gh api --method POST -H "Accept: application/vnd.github+json" \
  /repos/<GITHUB_USERNAME>/<REPO_NAME>/pages \
  -f source[branch]=main -f source[path]=/docs
```

If already exists, update:

```bash
gh api --method PUT -H "Accept: application/vnd.github+json" \
  /repos/<GITHUB_USERNAME>/<REPO_NAME>/pages \
  -f source[branch]=main -f source[path]=/docs
```

Optional recommended:

```bash
touch docs/.nojekyll
git add docs/.nojekyll
git commit -m "Add .nojekyll"
git push
```

Verify:

```bash
curl -I https://<GITHUB_USERNAME>.github.io/<REPO_NAME>/index.yaml
# Expect HTTP 200
```

---

## 10) Clone and Test Install from Hosted Helm Repo

Clone:

```bash
cd ~/Emplay
git clone https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
cd <REPO_NAME>
```

Add helm repo:

```bash
helm repo add cpucheck https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
helm repo update
helm search repo cpucheck
```

### Testing install (IMPORTANT: avoid conflicts)

If you already installed `cpucheck` in `default`, install into a new namespace:

```bash
kubectl create namespace cpucheck-test
helm install cpucheck1 cpucheck/cpucheck -n cpucheck-test \
  --set-string secrets.SMTP_PASSWORD="YOUR_APP_PASSWORD"
```

Manual run:

```bash
kubectl create job --from=cronjob/cpucheck-cron cpucheck-manual -n cpucheck-test
kubectl logs -n cpucheck-test job/cpucheck-manual --follow
```

---

## 11) Uninstall & Cleanup After Testing

### 11.1 Uninstall Helm release

If installed in default:

```bash
helm uninstall cpucheck -n default
```

If installed in test namespace:

```bash
helm uninstall cpucheck1 -n cpucheck-test
```

### 11.2 Delete test namespace (if created for testing)

```bash
kubectl delete namespace cpucheck-test
```

### 11.3 Optional cleanup (only if resources still exist)

Check remaining resources:

```bash
kubectl get cronjob,job,pod,cm,secret,sa -A | grep cpucheck
kubectl get pvc -A | grep -E "cpucheck|self-heal-logs"
kubectl get clusterrole,clusterrolebinding | grep cpucheck
```

If PVCs exist (delete only if you want to remove storage):

```bash
kubectl delete pvc cpucheck-state-pvc -n <namespace>
kubectl delete pvc self-heal-logs-pvc -n <namespace>
```

If ClusterRole/Binding exist:

```bash
kubectl delete clusterrole cpucheck-role
kubectl delete clusterrolebinding cpucheck-binding
```

---

