---
layout: single
title: Playing Around With AWS Rekognition
date: 2021-10-07
---

A dev I've been working with has had an [AWS DeepLens](https://aws.amazon.com/deeplens/) tossed on his desk and told to "build 
something awesome with it." He comes hit me up for inspiration. So I just start Googling what other people have done. 

An implementation I came across a few times was to use the DeepLens for general object detection then send the frame off to 
[Rekognition](https://aws.amazon.com/rekognition/) for more advanced analysis. Now, I may not have the DeepLens itself in my 
hands, but I can still play around with Rekognitions baked in functions.

## PPE Detection

A pretty cool function of Rekognition is to detect if a person is wearing gloves or a mask. This is done with the 
`detect_protective_equipment` function.

```python
import base64
import boto3
import json
import sys

rekognition = boto3.client('rekognition')

filename = sys.argv[1]

with open(filename, 'rb') as f:
    image = f.read()

res = rekognition.detect_protective_equipment(
        Image={
            'Bytes': image 
        }
    )

print(json.dumps(res, indent=4, sort_keys=True))
```

This is the image we're going to run against:

<a title="Javed Anees, CC0, via Wikimedia Commons" 
href="https://commons.wikimedia.org/wiki/File:Healthcare_workers_wearing_PPE_03.jpg"><img width="512" 
alt="Healthcare workers wearing PPE 03" 
src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Healthcare_workers_wearing_PPE_03.jpg/512px-Healthcare_workers_wearing_PPE_03.jpg">
</a>

Running against the image we get

```json
{
    "Persons": [
        {
            "BodyParts": [
                {
                    "Confidence": 93.98725891113281,
                    "EquipmentDetections": [
                        {
                            "BoundingBox": {
                                "Height": 0.1895013451576233,
                                "Left": 0.5032418370246887,
                                "Top": 0.16426366567611694,
                                "Width": 0.12380193173885345
                            },
                            "Confidence": 96.7356948852539,
                            "CoversBodyPart": {
                                "Confidence": 99.9734878540039,
                                "Value": true
                            },
                            "Type": "FACE_COVER"
                        }
                    ],
                    "Name": "FACE"
                },
                {
                    "Confidence": 97.83950805664062,
                    "EquipmentDetections": [
                        {
                            "BoundingBox": {
                                "Height": 0.32249826192855835,
                                "Left": 0.4805949926376343,
                                "Top": 0.0063177612610161304,
                                "Width": 0.20271863043308258
                            },
                            "Confidence": 97.84740447998047,
                            "CoversBodyPart": {
                                "Confidence": 90.17861938476562,
                                "Value": true
                            },
                            "Type": "HEAD_COVER"
                        }
                    ],
                    "Name": "HEAD"
                }
            ],
            "BoundingBox": {
                "Height": 0.9791666865348816,
                "Left": 0.41718751192092896,
                "Top": 0.011111111380159855,
                "Width": 0.3921875059604645
            },
            "Confidence": 99.381103515625,
            "Id": 0
        }
...
```

## Face Detection 

Moving on from this, we played around with simple face detection.


```python
import base64
import boto3
import json 
import sys

rekognition = boto3.client('rekognition')

filename = sys.argv[1]

with open(filename, 'rb') as f:
    image = f.read()

res = rekognition.detect_faces(
        Image={
            'Bytes': image 
        }
    )

print(json.dumps(res, indent=4, sort_keys=True))
```

However it only detected two faces in the same image.

```json
{
    "FaceDetails": [
        {
            "BoundingBox": {
                "Height": 0.17331033945083618,
                "Left": 0.31406813859939575,
                "Top": 0.24222606420516968,
                "Width": 0.08140096813440323
            },
            "Confidence": 99.99088287353516,
            "Landmarks": [
                {
                    "Type": "eyeLeft",
                    "X": 0.3451152741909027,
                    "Y": 0.3042142391204834
                },
                {
                    "Type": "eyeRight",
                    "X": 0.3797382414340973,
                    "Y": 0.31130728125572205
                },
                {
                    "Type": "mouthLeft",
                    "X": 0.34323662519454956,
                    "Y": 0.38228607177734375
                },
                {
                    "Type": "mouthRight",
                    "X": 0.37218159437179565,
                    "Y": 0.3882775902748108
                },
                {
                    "Type": "nose",
                    "X": 0.35931596159935,
                    "Y": 0.35247793793678284
                }
            ],
            "Pose": {
                "Pitch": -4.998554229736328,
                "Roll": -0.5071427226066589,
                "Yaw": 0.06535697728395462
            },
            "Quality": {
                "Brightness": 76.15126037597656,
                "Sharpness": 53.330047607421875
            }
        },
...
```

## People Detection

An issue with the face detection was that it only detected faces. If you're looking away or not at the camera at the correct 
angle it'd miss you. However, when toying around I noticed that the PPE detector will report on people not wearing any PPE. 
This means we can use it as a people detector.

It was about this time I was also getting sick of reading JSON outputs, so I tossed OpenCV in the mix.

```python
import base64
import boto3
import cv2
import sys

rekognition = boto3.client('rekognition')

filename = sys.argv[1]
output_filename = sys.argv[2]

with open(filename, 'rb') as f:
    image = f.read()

res = rekognition.detect_protective_equipment(
        Image={
            'Bytes': image 
        }
    )

cv_image = cv2.imread(filename)
height, width, _ = cv_image.shape

for person in res['Persons']:
    start_x = width * person['BoundingBox']['Left']
    start_y = height * person['BoundingBox']['Top']
    end_x = width * person['BoundingBox']['Width'] + start_x
    end_y = height * person['BoundingBox']['Height'] + start_y 

    start = (int(start_x), int(start_y))
    end = (int(end_x), int(end_y))

    cv_image = cv2.rectangle(cv_image, start, end, (255,0,0), 1)

cv2.imwrite(output_filename, cv_image)
```

<a title="Javed Anees, CC0, via Wikimedia Commons" 
href="https://commons.wikimedia.org/wiki/File:Healthcare_workers_wearing_PPE_03.jpg"><img width="512" 
src="/assets/posts/playing-with-rekognition/healthcare_workers.jpg"></a>

<a title="Peter Hershey peterhershey, CC0, via Wikimedia Commons" 
href="https://commons.wikimedia.org/wiki/File:Man_facing_stairs_and_traffic_(Unsplash).jpg"><img width="512" 
src="/assets/posts/playing-with-rekognition/man_facing_stairs_and_traffic.jpg"></a>

Now this was only a couple of simple demos, but it showed that it was possible to get up and running with some really cool shit 
super fast. Definitely need to play around with it some more.
