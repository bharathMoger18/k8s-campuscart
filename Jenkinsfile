// Jenkinsfile
// Lives at the ROOT of the k8s-campuscart repo. This is "pipeline as code" —
// the pipeline's behavior is versioned, reviewable, and travels with the app,
// not configured by clicking around in Jenkins' UI.

pipeline {
    // No top-level 'agent' here — each STAGE defines its own pod, since
    // different stages need very different containers (test needs
    // Postgres/Redis; build needs Kaniko; deploy needs kubectl). Sharing
    // one giant pod for everything would waste resources on every build.
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
                    // Capture the commit SHA HERE, in the one stage that
                    // actually has git available. Later stages (Kaniko,
                    // deploy) don't have git installed at all — they're
                    // minimal, purpose-built images, not general Linux
                    // boxes. env.X set here persists for the WHOLE pipeline
                    // run (it lives in Jenkins' build context, not inside
                    // any one pod), so every later stage can just read
                    // env.WEB_TAG and env.NGINX_TAG directly, no matter which pod it's in.
                    script {
                        sh 'git config --global --add safe.directory "$(pwd)"'
                        // Tag each image by the LAST COMMIT THAT TOUCHED ITS INPUTS, not by the
                        // current commit. A commit that only edits a manifest or the Jenkinsfile
                        // then gives the same tag as before, so the image build can be skipped.
                        //   web   is built from campuscart-backend/
                        //   nginx is built from nginx/, frontend/ and the root .dockerignore
                        def head     = sh(script: 'git rev-parse HEAD | cut -c1-7', returnStdout: true).trim()
                        def webTag   = sh(script: 'git log -1 --format=%H -- campuscart-backend | cut -c1-7', returnStdout: true).trim() ?: head
                        def nginxTag = sh(script: 'git log -1 --format=%H -- nginx frontend .dockerignore | cut -c1-7', returnStdout: true).trim() ?: head

                        // Ask the registry whether that tag already exists (a HEAD request for the
                        // manifest; BusyBox wget --spider exits non-zero on a 404). On any error the
                        // tag counts as missing, which only means we build (the safe default).
                        def accept = 'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'
                        def webExists   = sh(script: "wget -q --spider --header='Accept: ${accept}' http://192.168.1.3:5000/v2/campuscart-web/manifests/${webTag}", returnStatus: true) == 0
                        def nginxExists = sh(script: "wget -q --spider --header='Accept: ${accept}' http://192.168.1.3:5000/v2/campuscart-nginx/manifests/${nginxTag}", returnStatus: true) == 0

                        env.WEB_TAG      = webTag
                        env.NGINX_TAG    = nginxTag
                        env.WEB_EXISTS   = webExists ? 'true' : 'false'
                        env.NGINX_EXISTS = nginxExists ? 'true' : 'false'
                        echo "web tag ${webTag} (already in registry: ${webExists}); nginx tag ${nginxTag} (already in registry: ${nginxExists})"
                    }
                    // Stash the checked-out code so LATER stages (which run
                    // in COMPLETELY DIFFERENT pods) can retrieve it. Each
                    // stage's pod is created fresh and torn down after —
                    // nothing carries over between them automatically except
                    // what we explicitly stash/unstash.
                    stash name: 'source', includes: '**'
                }
            }
        }

        stage('Test') {
            when {
                // Same condition as the Security Scan: tests run only when the web image
                // is about to be rebuilt, so manifest-only commits stay fast.
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

  # This is the container our pipeline steps actually execute inside.
  # WHY "command: cat" + "tty: true": a plain python:3.12-slim image's
  # default process isn't designed to just sit there waiting for commands —
  # Jenkins needs this container to stay alive indefinitely so it can
  # `kubectl exec` into it once per pipeline step. `cat` with a tty attached
  # is the standard, well-known trick for this: a trivial, harmless process
  # that never exits on its own.
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
      # TEST-ONLY, throwaway values scoped to an ephemeral pod destroyed
      # the moment this stage ends — not the same risk category as a real
      # production secret.
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

                    // A pod's containers all START roughly in parallel —
                    // "Running" does NOT mean "ready to accept connections."
                    // Same principle as entrypoint.sh's wait-for-postgres logic.
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
            // Runs only when the web image is about to be built. It runs BEFORE
            // the build (not alongside it) on purpose: if the scan fails, no image
            // reaches the registry, so retrying the same commit cannot skip both
            // the scan and the build because the tag already exists.
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
                // beforeAgent: decide BEFORE Jenkins starts the Kaniko pod, so a skipped
                // stage costs nothing (no pod startup).
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
  # MUST use the :debug tag, not the minimal distroless production tag.
  # The distroless Kaniko image has NO shell binary at all — Jenkins'
  # Kubernetes plugin runs every pipeline step by exec-ing a shell inside
  # the container, so with zero shell present, every step would fail
  # instantly.
  #
  # TWO SEPARATE containers, one per image, rather than one container
  # running both builds sequentially. Kaniko is memory-hungry (full
  # filesystem snapshots after each instruction) — running both builds in
  # ONE container risks the second build inheriting memory pressure from
  # the first and getting OOM-killed. Separate containers = separate
  # memory ceilings.
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
                    // --insecure / --insecure-pull: our registry serves
                    // plain HTTP, no TLS. A real company's registry would
                    // have real TLS and these flags simply wouldn't exist.
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
  # This is the ONLY stage using this ServiceAccount — it's what actually
  # grants kubectl inside this Pod permission to update Deployments in
  # k8s-campuscart. Every other stage uses the default jenkins-agent
  # identity, which CANNOT do this — least privilege applied per-task.
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
            // Replace the existing `steps { container('kubectl') { sh '''...''' } }`
// block inside the Deploy stage with this. Everything below the
// migration section is your EXISTING code, unchanged — only the top
// part (Job delete/apply/wait) is new.
//
// Note on `kubectl wait --for=condition=complete`: it only matches a
// Job reaching Complete. If the Job instead FAILS (hits backoffLimit),
// it gets a Failed condition, which wait does NOT match — so a real
// failure isn't detected immediately, it just times out after the
// full --timeout window, then errors (correctly failing the pipeline,
// just slower than an explicit failure check would be). The `||`
// block below at least dumps the Job's logs to the Jenkins console
// when that happens, so a failure is debuggable without needing to
// kubectl exec/describe by hand afterward.
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

    // Failure notification: runs after ANY stage fails. Posts a short message to a chat
    // webhook whose URL lives in the Jenkins credential 'notify-webhook' (never in git).
    // A missing credential or a failed POST is logged and swallowed: a broken notifier must
    // never change the build result or hang the pipeline.
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
