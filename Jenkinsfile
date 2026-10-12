// Terraform delivery pipeline: validate -> policy -> plan -> approve -> apply -> evidence.
//
// LAB mode (default): AWS access keys stored as a Jenkins credential "aws-lab".
// REAL environments: the agent runs in the Shared Services account with an
// instance/pod role and assumes terraform-deploy in the target account. No static keys.

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()          // one run per job at a time (state lock is the second safety net)
    buildDiscarder(logRotator(numToKeepStr: '50'))
    timeout(time: 2, unit: 'HOURS')
  }

  parameters {
    choice(name: 'ACTION', choices: ['plan', 'apply', 'drift-check', 'destroy'], description: 'What to do')
    string(name: 'STACK_DIR', defaultValue: 'lab', description: 'Terraform root module directory')
    choice(name: 'ENV', choices: ['lab', 'dev', 'staging', 'prod'], description: 'Target environment')
    string(name: 'TF_STATE_BUCKET', defaultValue: '', description: 'S3 state bucket from terraform/bootstrap')
    string(name: 'AWS_REGION', defaultValue: 'ap-southeast-1', description: 'Region of the state bucket')
  }

  environment {
    TF_IN_AUTOMATION = 'true'
    TF_INPUT         = '0'
    PLAN_FILE        = 'tfplan'
    EVIDENCE_PREFIX  = "evidence/${params.ENV}/${env.JOB_NAME}/${env.BUILD_NUMBER}"
    APPROVERS        = 'admin'          // Jenkins user/group allowed to approve (use an LDAP/SSO group in real life)
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse HEAD').trim()
          env.GIT_AUTHOR = sh(returnStdout: true, script: 'git log -1 --pretty=%ae').trim()
          if (!params.TF_STATE_BUCKET?.trim()) { error 'TF_STATE_BUCKET is required' }
        }
        echo "Commit ${env.GIT_SHA} by ${env.GIT_AUTHOR}"
      }
    }

    stage('Init') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
          sh '''
            terraform -chdir="$STACK_DIR" init -reconfigure \
              -backend-config="bucket=$TF_STATE_BUCKET" \
              -backend-config="key=$STACK_DIR/$ENV/terraform.tfstate" \
              -backend-config="region=$AWS_REGION" \
              -backend-config="encrypt=true" \
              -backend-config="use_lockfile=true"
          '''
        }
      }
    }

    stage('Validate') {
      steps {
        sh 'terraform fmt -check -recursive "$STACK_DIR"'
        sh 'terraform -chdir="$STACK_DIR" validate'
        sh 'cd "$STACK_DIR" && tflint --init && tflint'
      }
    }

    stage('Static policy (Checkov)') {
      steps {
        script {
          // Hard-fail in prod; report-only elsewhere so you can learn from the findings.
          def soft = (params.ENV == 'prod') ? '' : '--soft-fail'
          sh "checkov -d \"${params.STACK_DIR}\" --framework terraform --compact ${soft} -o cli -o junitxml --output-file-path console,checkov-report.xml"
        }
      }
      post { always { junit allowEmptyResults: true, testResults: 'checkov-report.xml' } }
    }

    stage('Plan') {
      when { expression { params.ACTION != 'destroy' } }
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
          script {
            // -detailed-exitcode: 0 = no changes, 1 = error, 2 = changes present
            def rc = sh(returnStatus: true, script: 'terraform -chdir="$STACK_DIR" plan -out="$PLAN_FILE" -detailed-exitcode -no-color > plan.txt; rc=$?; cat plan.txt; exit $rc')
            if (rc == 1) { error 'terraform plan failed' }
            env.HAS_CHANGES = (rc == 2) ? 'true' : 'false'
            sh 'terraform -chdir="$STACK_DIR" show -json "$PLAN_FILE" > plan.json'
          }
        }
        echo "Changes present: ${env.HAS_CHANGES}"
      }
    }

    stage('Plan policy (Conftest/OPA)') {
      when { expression { params.ACTION != 'destroy' } }
      steps {
        sh 'conftest test --policy policy/ plan.json --output junit > conftest-report.xml || (cat conftest-report.xml; exit 1)'
      }
      post { always { junit allowEmptyResults: true, testResults: 'conftest-report.xml' } }
    }

    stage('Drift report') {
      when { expression { params.ACTION == 'drift-check' } }
      steps {
        script {
          if (env.HAS_CHANGES == 'true') {
            unstable('DRIFT DETECTED: real infrastructure differs from Git. See plan.txt')
          } else {
            echo 'No drift: infrastructure matches Git.'
          }
        }
      }
    }

    stage('Approval') {
      when { expression { params.ACTION == 'apply' && env.HAS_CHANGES == 'true' } }
      steps {
        script {
          def who = input(
            message: "Apply plan for ${params.STACK_DIR}/${params.ENV} at ${env.GIT_SHA.substring(0, 8)}? Review plan.txt in build artifacts.",
            ok: 'Approve and apply',
            submitter: env.APPROVERS,
            submitterParameter: 'APPROVER'
          )
          env.APPROVER = who
          // Segregation of duties: in real environments the approver must not be the commit author.
          if (params.ENV == 'prod' && env.APPROVER == env.GIT_AUTHOR) {
            error "Approver ${env.APPROVER} cannot approve their own change"
          }
        }
      }
    }

    stage('Apply') {
      when { expression { params.ACTION == 'apply' && env.HAS_CHANGES == 'true' } }
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
          // Apply the SAVED plan: exactly what was reviewed, nothing more.
          sh 'terraform -chdir="$STACK_DIR" apply -no-color "$PLAN_FILE" | tee apply.txt'
        }
      }
    }

    stage('Post-apply verification') {
      when { expression { params.ACTION == 'apply' && env.HAS_CHANGES == 'true' } }
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
          script {
            def rc = sh(returnStatus: true, script: 'terraform -chdir="$STACK_DIR" plan -detailed-exitcode -no-color > postcheck.txt')
            if (rc != 0) { error 'Post-apply plan is not clean: investigate before closing the change' }
          }
        }
      }
    }

    stage('Destroy (lab only)') {
      when { expression { params.ACTION == 'destroy' } }
      steps {
        script { if (params.ENV != 'lab') { error 'Destroy is only allowed in the lab' } }
        input message: "Destroy ${params.STACK_DIR}/${params.ENV}?", ok: 'Destroy', submitter: env.APPROVERS
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
          sh 'terraform -chdir="$STACK_DIR" destroy -auto-approve -no-color | tee destroy.txt'
        }
      }
    }
  }

  post {
    always {
      // Evidence: who, what, when, approved by whom. Real environments write to an
      // Object Lock (compliance mode) bucket in the Log Archive account.
      script { env.TS = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim() }
      writeFile file: 'evidence.json', text: """{
  "job": "${env.JOB_NAME}", "build": "${env.BUILD_NUMBER}", "action": "${params.ACTION}",
  "stack": "${params.STACK_DIR}", "env": "${params.ENV}", "commit": "${env.GIT_SHA}",
  "author": "${env.GIT_AUTHOR}", "approver": "${env.APPROVER ?: 'n/a'}",
  "result": "${currentBuild.currentResult}", "timestamp": "${env.TS}"
}"""
      archiveArtifacts artifacts: 'plan.txt,plan.json,apply.txt,postcheck.txt,destroy.txt,evidence.json,*-report.xml', allowEmptyArchive: true
      withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-lab']]) {
        sh '''
          for f in plan.txt plan.json apply.txt postcheck.txt destroy.txt evidence.json; do
            [ -f "$f" ] && aws s3 cp "$f" "s3://$TF_STATE_BUCKET/$EVIDENCE_PREFIX/$f" --region "$AWS_REGION" || true
          done
        '''
      }
    }
  }
}
