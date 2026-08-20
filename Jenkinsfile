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
    image: bitnami/kubectl:1.29
    command: ["cat"]
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
                        kubectl set image deployment/web web=192.168.1.3:5000/campuscart-web:${IMAGE_TAG} -n k8s-campuscart
                        kubectl set image deployment/nginx nginx=192.168.1.3:5000/campuscart-nginx:${IMAGE_TAG} -n k8s-campuscart

                        # rollout status BLOCKS until the new Pods are actually
                        # Ready (or fails after the timeout) — this turns
                        # "I told Kubernetes to update" into a real pass/fail
                        # signal for the pipeline, not fire-and-forget.
                        kubectl rollout status deployment/web -n k8s-campuscart --timeout=180s
                        kubectl rollout status deployment/nginx -n k8s-campuscart --timeout=120s
                    '''
                }
            }
        }
    }
}