pipeline {
    agent none

    stages {

        stage('Checkout') {
            agent {
                kubernetes {
                    yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: git
    image: alpine/git:latest
    command: ["cat"]
    tty: true
'''
                }
            }
            steps {
                container('git') {
                    checkout scm
                    script {
                        sh 'git config --global --add safe.directory "$(pwd)"'
                        def head     = sh(script: 'git rev-parse HEAD | cut -c1-7', returnStdout: true).trim()
                        def webTag   = sh(script: 'git log -1 --format=%H -- campuscart-backend | cut -c1-7', returnStdout: true).trim() ?: head
                        def nginxTag = sh(script: 'git log -1 --format=%H -- nginx frontend .dockerignore | cut -c1-7', returnStdout: true).trim() ?: head

                        def accept = 'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'
                        def webExists   = sh(script: "wget -q --spider --header='Accept: ${accept}' http://192.168.1.3:5000/v2/campuscart-web/manifests/${webTag}", returnStatus: true) == 0
                        def nginxExists = sh(script: "wget -q --spider --header='Accept: ${accept}' http://192.168.1.3:5000/v2/campuscart-nginx/manifests/${nginxTag}", returnStatus: true) == 0

                        env.WEB_TAG      = webTag
                        env.NGINX_TAG    = nginxTag
                        env.WEB_EXISTS   = webExists ? 'true' : 'false'
                        env.NGINX_EXISTS = nginxExists ? 'true' : 'false'
                        echo "web tag ${webTag} (already in registry: ${webExists}); nginx tag ${nginxTag} (already in registry: ${nginxExists})"
                    }
                    stash name: 'source', includes: '**'
                }
            }
        }

        stage('Test') {
            when {
                beforeAgent true
                expression { env.WEB_EXISTS != 'true' }
            }
            agent {
                kubernetes {
                    yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: python
    image: python:3.12-slim
    command: ["cat"]
    tty: true
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "1"
        memory: "1Gi"
    env:
      - name: DB_HOST
        value: "localhost"
      - name: DB_PORT
        value: "5432"
      - name: DB_NAME
        value: "test_campuscart_db"
      - name: DB_USER
        value: "test_user"
      - name: DB_PASSWORD
        value: "test_pass"
      - name: REDIS_HOST
        value: "localhost"
      - name: REDIS_PORT
        value: "6379"
      - name: DJANGO_SECRET_KEY
        value: "ci-test-only-not-a-real-secret-00000000"
      - name: DEBUG
        value: "True"
      - name: ALLOWED_HOSTS
        value: "localhost,127.0.0.1"

  - name: postgres
    image: postgres:15-alpine
    env:
      - name: POSTGRES_DB
        value: "test_campuscart_db"
      - name: POSTGRES_USER
        value: "test_user"
      - name: POSTGRES_PASSWORD
        value: "test_pass"
    resources:
      requests:
        cpu: "250m"
        memory: "256Mi"

  - name: redis
    image: redis:7-alpine
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
'''
                }
            }
            steps {
                container('python') {
                    unstash 'source'
                    sh '''
                        apt-get update -qq && apt-get install -y -qq netcat-openbsd > /dev/null
                        until nc -z localhost 5432; do echo "Waiting for Postgres..."; sleep 2; done
                        until nc -z localhost 6379; do echo "Waiting for Redis..."; sleep 2; done
                        echo "Postgres and Redis are ready."
                    '''

                    sh '''
                        cd campuscart-backend
                        pip install --no-cache-dir -r requirements.txt
                    '''

                    sh '''
                        cd campuscart-backend
                        python manage.py test --noinput --verbosity=2
                    '''
                }
            }
        }

        stage('Security Scan') {
            when {
                beforeAgent true
                expression { env.WEB_EXISTS != 'true' }
            }
            agent {
                kubernetes {
                    yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: python
    image: python:3.12-slim
    command: ["cat"]
    tty: true
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
'''
                }
            }
            steps {
                container('python') {
                    unstash 'source'
                    sh '''
                        pip install --no-cache-dir -q pip-audit bandit
                        cd campuscart-backend
                        # bandit: fail on MEDIUM severity and above (-ll). Today it only reports
                        # Low findings (fixture passwords in tests, two try/except/pass).
                        bandit -r . -q -ll
                        # pip-audit: fail on ANY known vulnerability in the pinned versions.
                        pip-audit -r requirements.txt --no-deps --disable-pip
                    '''
                }
            }
        }

        stage('Build and Push Images') {
            when {
                beforeAgent true
                expression { env.WEB_EXISTS != 'true' || env.NGINX_EXISTS != 'true' }
            }
            agent {
                kubernetes {
                    yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kaniko-web
    image: gcr.io/kaniko-project/executor:debug
    command: ["cat"]
    tty: true
    resources:
      requests:
        cpu: "500m"
        memory: "1Gi"
      limits:
        cpu: "2"
        memory: "2Gi"
  - name: kaniko-nginx
    image: gcr.io/kaniko-project/executor:debug
    command: ["cat"]
    tty: true
    resources:
      requests:
        cpu: "250m"
        memory: "512Mi"
      limits:
        cpu: "1"
        memory: "1Gi"
'''
                }
            }
            steps {
                container('kaniko-web') {
                    unstash 'source'
                    sh '''
                        if [ "${WEB_EXISTS}" = "true" ]; then echo "web image ${WEB_TAG} is already in the registry, skipping its build"; exit 0; fi
                        /kaniko/executor \
                          --context=dir://$(pwd)/campuscart-backend \
                          --dockerfile=$(pwd)/campuscart-backend/Dockerfile \
                          --destination=192.168.1.3:5000/campuscart-web:${WEB_TAG} \
                          --destination=192.168.1.3:5000/campuscart-web:latest \
                          --insecure \
                          --insecure-pull \
                          --cache=true
                    '''
                }

                container('kaniko-nginx') {
                    unstash 'source'
                    sh '''
                        if [ "${NGINX_EXISTS}" = "true" ]; then echo "nginx image ${NGINX_TAG} is already in the registry, skipping its build"; exit 0; fi
                        /kaniko/executor \
                          --context=dir://$(pwd) \
                          --dockerfile=$(pwd)/nginx/Dockerfile \
                          --destination=192.168.1.3:5000/campuscart-nginx:${NGINX_TAG} \
                          --destination=192.168.1.3:5000/campuscart-nginx:latest \
                          --insecure \
                          --insecure-pull \
                          --cache=true
                    '''
                }
            }
        }

        stage('Deploy') {
            agent {
                kubernetes {
                    yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-deployer
  containers:
  - name: kubectl
    image: alpine/k8s:1.29.15
    command:
    - cat
    tty: true
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "250m"
        memory: "256Mi"
'''
                }
            }
          steps {
                container('kubectl') {
                    sh '''
                        [ -n "${WEB_TAG}" ] && [ -n "${NGINX_TAG}" ] || { echo "WEB_TAG or NGINX_TAG is empty, refusing to deploy"; exit 1; }
                        echo "=== Running database migrations ==="
                        kubectl delete job campuscart-migrate -n k8s-campuscart --ignore-not-found

                        envsubst '${WEB_TAG}' < k8s/migrate-job.yaml | kubectl apply -f -

                        kubectl wait --for=condition=complete job/campuscart-migrate -n k8s-campuscart --timeout=180s || {
                            echo "=== Migration Job did not complete — dumping logs ==="
                            kubectl logs job/campuscart-migrate -n k8s-campuscart --tail=100
                            exit 1
                        }
                        echo "=== Migrations complete ==="

                        echo "=== Applying full manifests (real GitOps, not just image tag) ==="
                        envsubst '${WEB_TAG}' < k8s/web.yaml | kubectl apply -f -
                        envsubst '${NGINX_TAG}' < k8s/nginx.yaml | kubectl apply -f -

                        rollout_or_rollback() {
                            dep="$1"
                            limit="$2"
                            ns="${NS:-k8s-campuscart}"
                            if kubectl rollout status "deployment/${dep}" -n "${ns}" --timeout="${limit}"; then
                                return 0
                            fi
                            echo "=== rollout of ${dep} did not finish within ${limit}: diagnostics ==="
                            kubectl get pods -n "${ns}" -l "app=${dep}" -o wide || true
                            kubectl get events -n "${ns}" --sort-by=.lastTimestamp | tail -15 || true
                            newest=$(kubectl get rs -n "${ns}" -l "app=${dep}" --sort-by=.metadata.creationTimestamp -o name | tail -1)
                            if [ -z "${newest}" ]; then
                                echo "could not read the ReplicaSets, so not rolling back automatically"
                                return 1
                            fi
                            desired=$(kubectl get "deployment/${dep}" -n "${ns}" -o jsonpath='{.spec.replicas}')
                            ready=$(kubectl get "${newest}" -n "${ns}" -o jsonpath='{.status.readyReplicas}')
                            if [ "${ready:-0}" -ge "${desired:-1}" ]; then
                                echo "${newest} has ${ready}/${desired} ready pods: healthy but slow, not rolling back"
                                return 0
                            fi
                            echo "=== ${newest} has ${ready:-0}/${desired} ready pods: rolling back deployment/${dep} ==="
                            kubectl rollout undo "deployment/${dep}" -n "${ns}"
                            kubectl rollout status "deployment/${dep}" -n "${ns}" --timeout=300s || true
                            return 1
                        }

                        rollout_or_rollback web 600s
                        rollout_or_rollback nginx 120s
                    '''
                }
            }
        }
    }
    
    post {
        failure {
            script {
                try {
                    timeout(time: 3, unit: 'MINUTES') {
                        podTemplate(yaml: '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: curl
    image: alpine/k8s:1.29.15
    command: ["cat"]
    tty: true
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "200m"
        memory: "128Mi"
''') {
                            node(POD_LABEL) {
                                container('curl') {
                                    withCredentials([string(credentialsId: 'notify-webhook', variable: 'HOOK')]) {
                                        sh '''
                                            MSG="CampusCart build #${BUILD_NUMBER} FAILED: ${BUILD_URL}"
                                            printf '{"text":"%s"}' "$MSG" > /tmp/payload.json
                                            curl -fsS -X POST -H 'Content-Type: application/json' --data @/tmp/payload.json "$HOOK"
                                        '''
                                    }
                                }
                            }
                        }
                    }
                } catch (err) {
                    echo "Failure notification skipped: ${err.message}"
                }
            }
        }
    }
}
