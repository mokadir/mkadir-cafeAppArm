#!/usr/bin/env groovy
// =============================================================================
// Cafe App Website — Jenkins CI/CD for Kubernetes agents
// Builds static site using Python generator, packages with Nginx,
// pushes to Docker Hub
// =============================================================================

pipeline {
    agent {
        kubernetes {
            label 'cafeapp-buildkit-agent'
            defaultContainer 'tools'
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  namespace: ns-jenkins
spec:
  serviceAccountName: jenkins
  containers:
    - name: tools
      image: docker:24.0.2
      command: ['sh', '-c', 'cat']
      tty: true
    - name: buildkit
      image: moby/buildkit:v0.11.0
      command: ['buildkitd', '--addr', 'tcp://0.0.0.0:1234']
      tty: true
    - name: trivy
      image: aquasec/trivy:0.52.2
      command: ['sh', '-c', 'cat']
      tty: true
'''
        }
    }

    parameters {
        string(name: 'DOCKERHUB_ORG', defaultValue: 'mokadir', description: 'Docker Hub organisation/username')
        string(name: 'IMAGE_TAG', defaultValue: '${BUILD_NUMBER}', description: 'Image tag. Leave empty to auto-generate from Jenkins build number')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch to build from')
        choice(name: 'BUILD_ENV', choices: ['staging', 'production'], description: 'Target environment')
        booleanParam(name: 'RUN_CONTAINER_SCAN', defaultValue: true, description: 'Run Trivy image scan after build')
        booleanParam(name: 'PUSH_IMAGE', defaultValue: true, description: 'Push image to Docker Hub')
        booleanParam(name: 'PUSH_LATEST_TAG', defaultValue: true, description: 'Also push :latest on main/production')
        string(name: 'TRIVY_SEVERITY', defaultValue: 'HIGH,CRITICAL', description: 'Trivy severity threshold')
        booleanParam(name: 'FAIL_ON_VULN', defaultValue: false, description: 'Fail build on vulnerabilities')
        string(name: 'SLACK_CHANNEL', defaultValue: '', description: 'Optional Slack channel for notifications')
        choice(name: 'BUILD_PLATFORM', choices: ['linux/arm64', 'linux/amd64', 'all'], description: 'Target platform/architecture for the Docker image. Use "all" to build both amd64 and arm64')
    }

    environment {
        DOCKERHUB_ORG = "${params.DOCKERHUB_ORG}"
        BUILD_ENV = "${params.BUILD_ENV}"
        TRIVY_SEVERITY = "${params.TRIVY_SEVERITY}"
        IMAGE_TAG = "${params.IMAGE_TAG}"
        BUILD_PLATFORM = "${params.BUILD_PLATFORM}"
        SHORT_SHA = ''
        APP_NAME = 'cafeapp-arm'
    }

    options {
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
        timestamps()
    }

    stages {
        stage('Checkout') {
            steps {
                container('tools') {
                    sh 'apk add --no-cache git'
                }
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: "*/${params.GIT_BRANCH}"]],
                    extensions: [[$class: 'CleanBeforeCheckout']],
                    userRemoteConfigs: scm.userRemoteConfigs
                ])
            }
        }

        stage('Resolve Metadata') {
            steps {
                container('tools') {
                    sh 'apk add --no-cache git'
                }
                script {
                    sh 'git config --global --add safe.directory ${WORKSPACE}'
                    env.SHORT_SHA = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    def rawTag = params.IMAGE_TAG?.trim()
                    def safeBranch = params.GIT_BRANCH.replaceAll('[^a-zA-Z0-9._-]', '-').toLowerCase()
                    env.IMAGE_TAG = rawTag ? rawTag : "${safeBranch}-${env.SHORT_SHA}"
                    echo "Organisation : ${env.DOCKERHUB_ORG}"
                    echo "Image Tag    : ${env.IMAGE_TAG}"
                    echo "Branch       : ${params.GIT_BRANCH}"
                    echo "Environment  : ${env.BUILD_ENV}"
                    echo "Platform     : ${params.BUILD_PLATFORM}"
                    echo "Commit SHA   : ${env.SHORT_SHA}"
                }
            }
        }

        stage('Preflight') {
            steps {
                container('tools') {
                    sh '''
                        set -eux
                        apk update
                        apk add --no-cache python3 py3-pip curl ca-certificates bash
                        if ! command -v python >/dev/null 2>&1; then
                            ln -sf /usr/bin/python3 /usr/local/bin/python
                        fi
                        docker --version
                        docker buildx version
                    '''
                }
                container('trivy') {
                    sh 'trivy --version'
                }
            }
        }

        stage('Generate Static Site') {
            steps {
                container('tools') {
                    sh '''
                        set -eux
                        python3 generate.py
                        ls -la index.html
                        echo "Static site generated successfully"
                    '''
                }
            }
        }

        stage('Prepare Registry Auth') {
            when { expression { params.PUSH_IMAGE } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-cred', usernameVariable: 'DOCKERHUB_USERNAME', passwordVariable: 'DOCKERHUB_PASSWORD')]) {
                    container('tools') {
                        sh '''
                            set -eu
                            mkdir -p /root/.docker
                            cat > /root/.docker/config.json <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "username": "${DOCKERHUB_USERNAME}",
      "password": "${DOCKERHUB_PASSWORD}"
    }
  }
}
EOF
                        '''
                    }
                }
            }
        }

        stage('Build And Push Docker Image') {
            steps {
                script {
                    def targetPlatforms = params.BUILD_PLATFORM == 'all' ? ['linux/amd64', 'linux/arm64'] : [params.BUILD_PLATFORM]
                    def imageName = "${env.DOCKERHUB_ORG}/${env.APP_NAME}:${env.IMAGE_TAG}"
                    def latestTag = (params.PUSH_IMAGE && params.PUSH_LATEST_TAG) ? "${env.DOCKERHUB_ORG}/${env.APP_NAME}:latest" : ''
                    def buildArgs = [
                        "VCS_REF=${env.SHORT_SHA}",
                        "SOURCE_URL=https://github.com/${env.DOCKERHUB_ORG}/${env.APP_NAME}-website",
                        "VERSION=${env.IMAGE_TAG}",
                        "ENVIRONMENT=${env.BUILD_ENV}"
                    ]

                    try {
                        container('tools') {
                            sh '''
                                set -eux
                                export BUILDKIT_HOST=tcp://buildkit:1234
                                docker buildx rm jenkins-builder || true
                                docker buildx create --driver remote --name jenkins-builder --use
                                docker buildx ls
                            '''
                        }

                        if (params.PUSH_IMAGE) {
                            def platformList = targetPlatforms.join(',')
                            def buildCmd = "docker buildx build --platform ${platformList} --tag ${imageName}"
                            if (latestTag) {
                                buildCmd += " --tag ${latestTag}"
                            }
                            buildArgs.each { arg -> buildCmd += " --build-arg ${arg}" }
                            buildCmd += " --push ${env.WORKSPACE}"

                            container('tools') {
                                sh """
                                    set -eux
                                    echo 'Building image for platforms: ${platformList}'
                                    ${buildCmd}
                                """
                            }
                        } else {
                            for (platform in targetPlatforms) {
                                def arch = platform.tokenize('/')[1]
                                def archTarPath = "${env.WORKSPACE}/${env.APP_NAME}-${env.IMAGE_TAG}-${arch}.tar"
                                def buildCmd = "docker buildx build --platform ${platform}"
                                buildArgs.each { arg -> buildCmd += " --build-arg ${arg}" }
                                buildCmd += " --output type=tar,dest=${archTarPath} ${env.WORKSPACE}"

                                container('tools') {
                                    sh """
                                        set -eux
                                        echo 'Building image tar for platform: ${platform}'
                                        ${buildCmd}
                                    """
                                }
                            }
                        }

                        if (params.RUN_CONTAINER_SCAN) {
                            container('trivy') {
                                if (params.PUSH_IMAGE) {
                                    sh """
                                        trivy image \
                                            --exit-code ${params.FAIL_ON_VULN ? '1' : '0'} \
                                            --severity ${env.TRIVY_SEVERITY} \
                                            --format table \
                                            --output trivy-image-report.txt \
                                            ${imageName} || true
                                    """
                                } else {
                                    def tarList = targetPlatforms.collect { platform -> "${env.WORKSPACE}/${env.APP_NAME}-${env.IMAGE_TAG}-${platform.tokenize('/')[1]}.tar" }.join(' ')
                                    sh """
                                        for tarfile in ${tarList}; do
                                            trivy image \
                                                --input "${tarfile}" \
                                                --exit-code ${params.FAIL_ON_VULN ? '1' : '0'} \
                                                --severity ${env.TRIVY_SEVERITY} \
                                                --format table \
                                                --output "trivy-image-report-\$(basename \"${tarfile}\" .tar).txt" \
                                                || true
                                        done
                                    """
                                }
                            }
                            archiveArtifacts artifacts: 'trivy-image-report*.txt', allowEmptyArchive: true
                        }

                    } catch (err) {
                        echo "ERROR building image: ${err.message}"
                        currentBuild.result = 'UNSTABLE'
                        error("Image build failed: ${err.message}")
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (params.SLACK_CHANNEL?.trim()) {
                    try {
                        def status = currentBuild.currentResult
                        def color = status == 'SUCCESS' ? 'good' : (status == 'UNSTABLE' ? 'warning' : 'danger')
                        slackSend(
                            channel: params.SLACK_CHANNEL,
                            color: color,
                            message: "Cafe App CI/CD ${status} | Branch=${params.GIT_BRANCH} | Tag=${env.IMAGE_TAG} | Env=${env.BUILD_ENV} | Build=${env.BUILD_URL}",
                            tokenCredentialId: 'slack-bot-token'
                        )
                    } catch (ignored) {
                        echo 'Slack notification skipped'
                    }
                }
                cleanWs()
            }
        }

        failure {
            script {
                echo "Build failed. Check logs for details."
            }
        }

        success {
            script {
                def imageName = "${env.DOCKERHUB_ORG}/${env.APP_NAME}:${env.IMAGE_TAG}"
                echo "Build successful!"
                echo "Image: ${imageName}"
            }
        }
    }
}
