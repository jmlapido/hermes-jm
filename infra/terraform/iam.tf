data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hermes" {
  name               = "${var.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.hermes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.hermes.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Read-only access to /hermes/* parameters (incl. SecureString decryption
# via the SSM-managed KMS key, restricted to calls made through SSM).
data "aws_iam_policy_document" "hermes_params" {
  statement {
    sid = "ReadHermesParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:*:*:parameter/hermes",
      "arn:aws:ssm:*:*:parameter/hermes/*",
    ]
  }

  statement {
    sid       = "DecryptViaSSM"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "hermes_params" {
  name   = "${var.name}-ssm-params"
  role   = aws_iam_role.hermes.id
  policy = data.aws_iam_policy_document.hermes_params.json
}

resource "aws_iam_instance_profile" "hermes" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.hermes.name
}
