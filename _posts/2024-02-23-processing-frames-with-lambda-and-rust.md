---
layout: single
title: Processing Frames with Lambda and Rust
date: 2024-02-23
---

_This is a continuation of the [Processing Video with MediaConvert and Lambda]({% post_url 2023-04-16-processing-video-with-mediaconvert-and-lambda %}) post._

With the frames getting stored in S3 the next step is to process them. In this demo we're going to run a
[Sobel Operator](https://en.wikipedia.org/wiki/Sobel_operator) over them before saving in another S3 bucket.

Now my default GoTo for Lambda functions is Python. It's a popular enough language you can easily find help for.
However, any image processing library I know of includes C libraries that need compiling on install. This causes
problems because (as far as I'm aware) Pip doesn't support cross-compiling during library install. Which makes packaging
up Lambda functions from my Macbook more pain than I want to deal with for this solution.

So I start thinking "you've been meaning to try out Rust for a while, why not now?" Rust has a great
[Lambda tool](https://crates.io/crates/lambda_runtime). You can use it on your local machine and have it build Lambda
compatible binaries.

After getting a simple Hello World working in Lambda, I went on the hunt for a Sobel Operator library. I came across
[Edgy](https://github.com/dangreco/edgy) by a guy named Dan Greco. Edgy is a command line app rather than a library,
but I could pull what I needed from it.

From there it was a simple case of implementing the infrastructure to trigger the Lambda on new items to the frame
bucket, having the function process them, then save them into the output bucket.

## Output Bucket

Before we do anything else we need somewhere to store processed frames.

```hcl
resource "aws_s3_bucket" "processed_frames" {
  bucket = "mediaconvert-test-processed-frames-${random_string.suffix.result}"
}
```

## Modify Lambda Module

We're going to run our frame processor on an arm64 Lambda. Add the following variable to the module.

```hcl
variable "architectures" {
  description = "CPU architectures to run the Lambda function on"
  default     = ["x86_64"]
  type        = list(string)
}
```

And update the `aws_lambda_function` resource

```hcl
resource "aws_lambda_function" "lambda_function" {
  ...
  architectures = var.architectures
  ...
}
```

## Lambda Code

In the Lambda functions directory run this to create the function template

```bash
cargo lambda new frame-processor
```

It'll ask you some questions:

```
Is this function an HTTP function? N
AWS Event type that this function receives: s3::S3Event (scroll down to it)
```

Add the following dependencies to the `Cargo.toml`

```toml
anyhow = "1.0"
aws-config = "1.1.4"
aws-sdk-s3 =  "1.14.0"
image = "0.21.0"
serde = "1.0.196"
serde_json = "1.0.113"
```

In `main.rs` we want to import a few libraries. Most of this is standard Lambda stuff. `image` is the image library
we're going to use (duh). `tracing` is for logging. `mod sobel` refers to the `sobel.rs` we're going to create further
on.

```rust
extern crate aws_config;
extern crate aws_lambda_events;
extern crate aws_sdk_s3;
extern crate image;

use aws_config::{BehaviorVersion, load_defaults};
use aws_lambda_events::event::s3::S3Event;
use aws_sdk_s3::{Client, primitives::ByteStream};
use lambda_runtime::{run, service_fn, Error, LambdaEvent};
use std::{fs::File, io::Write, path::Path, env::var, str::FromStr};
use tracing::Level;

mod sobel;
```

A couple of static variables

```rust
static TMP_SOURCE_FILE: &str = "/tmp/source.jpg";
static TMP_OUTPUT_FILE: &str = "/tmp/output.jpg";
```

A function to process files. This will download the file from S3, run the Sobel Operator on it, then upload it to the
output bucket using the same key as the ingress object.

{% raw %}

```rust
async fn handle_record(client: Client, bucket: &str, key: &str) -> Result<(), Error> {
    tracing::debug!({%bucket, %key}, "Handling record");

    if !key.ends_with(".jpg") {
        tracing::info!({%key}, "File is not a JPEG image, exiting");
        return Ok(())
    }

    let output_bucket = var("OUTPUT_BUCKET").unwrap();
    let blur_modifier = var("BLUR_MODIFIER").unwrap().parse::<i32>().unwrap();

    let mut source_file = File::create(&TMP_SOURCE_FILE)?;
    let mut object = client
        .get_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await?;

    while let Some(bytes) = object.body.try_next().await? {
        source_file.write_all(&bytes)?;
    }
    tracing::debug!({%key, %TMP_SOURCE_FILE}, "Downloaded file from S3 to local disk");

    sobel::process_image(TMP_SOURCE_FILE, TMP_OUTPUT_FILE, blur_modifier);
    tracing::debug!({%TMP_SOURCE_FILE, %TMP_OUTPUT_FILE, %blur_modifier}, "Finished processing image");

    let body = ByteStream::from_path(Path::new(TMP_OUTPUT_FILE)).await;
    let _ = client
        .put_object()
        .bucket(&output_bucket)
        .key(key)
        .body(body.unwrap())
        .send()
        .await;
    tracing::debug!({%TMP_OUTPUT_FILE, %output_bucket, %key}, "Uploaded output file to S3");

    Ok(())
}
```

{% endraw %}

We need to update the `function_handler()` to process the incoming `S3Event`.

{% raw %}

```rust
#[tracing::instrument(skip(event), fields(req_id = %event.context.request_id))]
async fn function_handler(event: LambdaEvent<S3Event>) -> Result<(), Error> {
    let aws_config = load_defaults(BehaviorVersion::v2023_11_09()).await;
    let client = Client::new(&aws_config);

    for record in event.payload.records.iter() {
        let bucket = record.s3.bucket.name.clone().expect("Could not get bucket name from record");
        let key = record.s3.object.key.clone().expect("Could not get key from object record");

        tracing::debug!({%bucket, %key}, "Received new file");

        match handle_record(client.clone(), &bucket, &key).await {
            Ok(()) => {
                tracing::info!({%bucket, %key}, "Processed file");
            }
            Err(err) => {
                tracing::error!({%bucket, %key, %err}, "Failed to process file");
            }
        }
    }
    Ok(())
}
```

{% endraw %}

These events contain one or more records. Each record is a file that has been uploaded to S3. We pull the object key and
bucket name from the record and make a call to the `handle_record()` function.

In the `main()` function, we're going to update the logging functionality.

```rust
#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt().json()
        .with_max_level(Level::from_str(&std::env::var("LOG_LEVEL").unwrap()).unwrap())
        .with_current_span(false)   // remove duplicate information from the logs
        .without_time()             // disabling time is handy because CloudWatch will add the ingestion time.
        .with_target(false)         // disable printing the name of the module in every log line.
        .init();
    run(service_fn(function_handler)).await
}
```

What we've got here will take the event details from the S3 trigger, iterate over ever record in the event, and process
each image using the `process_image()` function from the `sobel` module.

For the module we need to create `sobel.rs` in the `src` directory. In here we're going to refactor some of the `Edgy`
app.

{% raw %}

```rust
use image::{GenericImageView, ImageBuffer, Luma};

pub fn process_image(source_filename: &str, output_filename: &str, blur_modifier: i32) {
    tracing::debug!({%source_filename, %output_filename, %blur_modifier}, "Starting image processing");
    let source = image::open(source_filename).unwrap();
    let (width, height) = source.dimensions();
    let sigma = (((width * height) as f32) / 3630000.0) * blur_modifier as f32;
    let gaussed = source.blur(sigma);
    let gray = gaussed.to_luma();

    let sobel_width:u32 = gray.width()-2;
    let sobel_height:u32 = gray.height()-2;
    let mut buff:ImageBuffer<Luma<u8>, Vec<u8>> = ImageBuffer::new(sobel_width, sobel_height);

    for i in 0..sobel_width {
        for j in 0..sobel_height {
            let val0 = gray.get_pixel(i, j).data[0] as i32;
            let val1 = gray.get_pixel(i+1, j).data[0] as i32;
            let val2 = gray.get_pixel(i+2, j).data[0] as i32;
            let val3 = gray.get_pixel(i, j+1).data[0] as i32;
            let val5 = gray.get_pixel(i+2, j+1).data[0] as i32;
            let val6 = gray.get_pixel(i, j+2).data[0] as i32;
            let val7 = gray.get_pixel(i+1, j+2).data[0] as i32;
            let val8 = gray.get_pixel(i+2, j+2).data[0] as i32;

            let gx = (-1*val0) + (-2*val3) + (-1*val6) + val2 + (2*val5) + val8;
            let gy = (-1*val0) + (-2*val1) + (-1*val2) + val6 + (2*val7) + val8;

            let mut mag = ((gx as f64).powi(2) + (gy as f64).powi(2)).sqrt();

            if mag > 255.0 {
                mag = 255.0;
            }

            buff.put_pixel(i, j, Luma([mag as u8]));
        }
    }


    buff.save(output_filename).unwrap();
}
```

{% endraw %}

You can compile the function with

```
cargo lambda build --release --arm64 --output-format binary
```

This will create a `target/lambda/frame-processor` directory that contains everything we need to upload to AWS.

## Lambda Function Infrastructure

Now that we've built our executable, we need to create the function in AWS. First we define the access our function
gets.

```terraform
data "aws_iam_policy_document" "frame_processor" {
  statement {
    sid = "WriteToCloudWatchLogs"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["*"]
  }

  statement {
    sid = "ReadFilesFromRawFramesBucket"

    actions = [
      "s3:GetObject"
    ]

    resources = [
      aws_s3_bucket.raw_frames.arn,
      "${aws_s3_bucket.raw_frames.arn}/*",
    ]
  }

  statement {
    sid = "WriteFilesToProcessedFramesBucket"

    actions = [
      "s3:PutObject"
    ]

    resources = [
      aws_s3_bucket.processed_frames.arn,
      "${aws_s3_bucket.processed_frames.arn}/*"
    ]
  }
}
```

This lets it pull images from the MediaConvert output and write to our Processed Frames bucket. It also grants
permissions to write logs.

For the function itself we're going to make use of our `lambda_function` module.

```terraform
module "frame_processor" {
  source = "./modules/lambda_function"

  function_name = "mediaconvert-frame-processor-${random_string.suffix.result}"
  iam_policy    = data.aws_iam_policy_document.frame_processor.json
  runtime       = "provided.al2"
  architectures = ["arm64"]
  handler       = "bootstrap"
  source_dir    = "${path.root}/lambda_functions/frame_processor/target/lambda/frame-processor"
  timeout       = 120

  environment_variables = {
    "OUTPUT_BUCKET" = aws_s3_bucket.processed_frames.bucket
    "BLUR_MODIFIER" = 8
    "LOG_LEVEL"     = "INFO"
  }
}
```

The `BLUR_MODIFIER` variable adjusts how much blur is used when processing the image. Adjust this until you find the
sweet spot.

Next we need to connect the function to the S3 bucket. This is done with a `aws_s3_bucket_notification` resource. We
want to filter for `ObjectCreated` events so the function gets run every time a new image gets uploaded to the bucket.

To allow the bucket to trigger the Lambda function we need an `aws_lambda_function` resource. This grants the bucket the
`InvokeFunction` permission.

```terraform
resource "aws_lambda_permission" "frame_processor_trigger" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = module.frame_processor.function_arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_frames.arn
}

resource "aws_s3_bucket_notification" "frame_processor_trigger" {
  bucket = aws_s3_bucket.raw_frames.id

  lambda_function {
    lambda_function_arn = module.frame_processor.function_arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.frame_processor_trigger]
}
```

## Testing

I'm sure once you've got all this deploy you're going to want to test it. The complete method would be to upload a video
to the ingress bucket. However, if you can't be bothered waiting for MediaConvert, you can simply upload a JPEG to the
frames bucket. It needs to have a `.jpg` file extension as we filter for it. If everything's working correctly you
should see a file show up in the ProcessedFrames bucket.

If you're having trouble, check out the
[complete diff](https://github.com/incpac/mediaconvert-frame-processor/commit/5db3050379bf534abbe8458cd35beb48676d5768)
for all changes made.

## Wrapping Up

With this we've got a pipeline that rips videos into frames and processes them. Next steps would be to update the
FrameProcessor to track the number of frames we've processed. We currently store the total number of frames in DynamoDB
but we may want to reconsider that due to the number of IO requests per video.

Once that's done we'll be able to tell when we've processed all frames for a particular video and we can stitch it back
together again. I'll aim to get that sorted sooner than the 10 months this post took.
