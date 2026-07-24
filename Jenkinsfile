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
                    // env.IMAGE_TAG directly, no matter which pod it's in.
                    script {
                        sh 'git config --global --add safe.directory "$(pwd)"'
                        env.IMAGE_TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
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
  # that never exits on its own. Without this, the container would start,
  # have nothing to do, and immediately exit — and Jenkins would have
  # nothing left to exec into.
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
      # These are TEST-ONLY, throwaway values scoped to an ephemeral pod
      # that's destroyed the moment this stage ends. This is NOT the same
      # category of risk as a real production secret — there is nothing
      # real behind these credentials, and no real database anyone could
      # reach with them after this pod dies. Hardcoding them directly in
      # the Jenkinsfile here is a legitimate, common practice for CI-only
      # values.
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
        value: "ci-test-only-not-a-real-secret"
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
                    // Postgres takes a moment to initialize even after its
                    // process starts. This is the EXACT same principle as
                    // entrypoint.sh's wait-for-postgres logic, just applied
                    // at the CI layer instead of the app-runtime layer.
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
                        python manage.py test --verbosity=2
                    '''
                }
            }
        }

        stage('Build and Push Images') {
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
  # instantly. :debug includes a tiny busybox shell specifically so tools
  # like Jenkins can drive it interactively.
  #
  # TWO SEPARATE containers, one per image, rather than one container
  # running both builds sequentially. Kaniko builds images by taking full
  # filesystem snapshots after each instruction — genuinely memory-hungry,
  # especially compiling gcc + ~70 Python packages. Running both builds in
  # ONE container means the second build inherits whatever memory the first
  # left allocated in that same cgroup, risking an OOM kill. Separate
  # containers means separate memory ceilings — one build can never starve
  # the other.
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
                    // plain HTTP, no TLS. Kaniko otherwise assumes HTTPS
                    // and would refuse to push. This is fine for a local,
                    // personal registry — a real company's registry would
                    // have real TLS, and these flags simply wouldn't exist
                    // in that pipeline.
                    sh '''
                        /kaniko/executor \
                          --context=dir://$(pwd)/campuscart-backend \
                          --dockerfile=$(pwd)/campuscart-backend/Dockerfile \
                          --destination=192.168.1.3:5000/campuscart-web:${IMAGE_TAG} \
                          --destination=192.168.1.3:5000/campuscart-web:latest \
                          --insecure \
                          --insecure-pull \
                          --cache=true
                    '''
                }

                container('kaniko-nginx') {
                    unstash 'source'

                    sh '''
                        /kaniko/executor \
                          --context=dir://$(pwd)/nginx \
                          --dockerfile=$(pwd)/nginx/Dockerfile \
                          --destination=192.168.1.3:5000/campuscart-nginx:${IMAGE_TAG} \
                          --destination=192.168.1.3:5000/campuscart-nginx:latest \
                          --insecure \
                          --insecure-pull \
                          --cache=true
                    '''
                }
            }
        }
    }
}