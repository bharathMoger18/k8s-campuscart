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
    }
}