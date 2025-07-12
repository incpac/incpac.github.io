---
layout: single
title: Go Concurrency Notes
date: 2025-07-12
---

So I was looking through some Go code Claude wrote for me the other day. It handles bulk uploads to S3. Naturally, not
being a Go developer, I had no idea what it was doing. This Go concurrency stuff might as well be written in ancient
Sumerian. But after getting it explained properly, I figured I'd write it down before my brain decides to forget it all
next week.

## The Setup

Picture this: you've got a function that needs to upload a bunch of files to S3, but you don't want to be a complete
savage and upload them one at a time. You also don't want to be an idiot and try to upload 10,000 files simultaneously
and bring down your entire infrastructure. What you need is something in between - a civilized approach that says "let's
do 10 at a time, and when one finishes, we can start the next."

This is where Go's concurrency patterns come in handy, assuming you can actually figure out what they're doing.

## Channels - The Magic Mailboxes

Channels in Go are basically message-passing tubes. Think of them like those pneumatic tubes at old-school banks, except
instead of cash deposits, you're sending Go structs around.

```go
resultChan chan<- UploadResult  // Send-only channel
semaphore chan struct{}         // Bidirectional channel
```

The `<-` arrow tells you which direction messages can flow:

- `chan<- Type` = send-only, you can put things in, but not take them out
- `<-chan Type` = receive-only, you can take things out, but not put them in
- `chan Type` = bidirectional

It's like having one-way streets for your data, which prevents you from accidentally reading from a channel you should
only be writing to. Very civilized.

## Semaphores - The Bouncer Pattern

Here's where it gets clever. A semaphore is basically a bouncer with a fixed number of VIP wristbands:

```go
semaphore := make(chan struct{}, 10)    // 10 wristbands available
semaphore <- struct{}{}                 // to start work, take a wristband

// do work here

<-semaphore                             // when done, return the wristband
```

The `struct{}{}` bit is just an empty struct that takes up zero memory. We don't care about the data - we just care
about counting how many operations are running.

When the channel buffer is full (all 10 wristbands are taken), any new goroutine trying to send to it will block and
wait. When someone finishes and takes a message out, the next goroutine automatically unblocks and continues. Go's
runtime handles all this blocking/unblocking automatically, which is pretty awesome.

## WaitGroups - The Attendance Tracker

WaitGroups are like a teacher doing attendance. You tell it "expect N students to finish their work" and it'll then wait
until all N report back that they're done.

This is crucial because if your `main()` function ends while goroutines are still running, the program just exits and
kills everything mid-flight.

## The Retry Logic

The upload function also has some retry logic with exponential backoff, which is just a fancy way of saying "if
something fails, wait a bit and try again, but wait longer each time." Which I suppose takes just as long to say.

```go
waitTime := time.Second * time.Duration(1<<attempt) // 1, 2, 4, 8 seconds...
```

That `1<<attempt` is bit shifting - it doubles the wait each retry. Much more elegant than hardcoding a bunch of sleep
values.

## Putting It All Together

Here's a complete example that shows how all these pieces work together:

```go
package main

import (
    "fmt"
    "sync"
    "time"
)

func main() {
    files := []string{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" }

    // create a semaphore that allows a max of 2 concurrent uploads
    semaphore := make(chan struct{}, 2)

    // create a waitgroup to track completion
    var wg sync.WaitGroup

    // create a channel to collect results
    resultChan := make(chan string, len(files))

    // start the uploads
    for _, file := range files {
        wg.Add(1) // expect one more worker to finish
        go uploadFile(file, semaphore, &wg, resultChan)
    }

    // wait for all uploads to complete
    wg.Wait()
    close(resultChan)

    // collect and print results
    fmt.Println("Upload results:")
    for result := range resultChan {
        fmt.Println(result)
    }
}

func uploadFile(filename string, semaphore chan struct{}, wg *sync.WaitGroup, results chan<- string) {
    defer wg.Done() // called when the function exits

    // grab a semaphore slot (blocks if all slots are taken)
    semaphore <- struct{}{}
    defer func() { <-semaphore }() // release the slot when done

    fmt.Printf("Starting upload: %s\n", filename)

    // retry logic with exponential backoff
    maxRetries := 3
    var err error

    for attempt := 0; attempt <= maxRetries; attempt++ {
        if attempt > 0 {
            // wait before retry with exponential backoff
            waitTime := time.Second * time.Duration(1<<attempt) // 1s, 2s, 4s, 8s...
            fmt.Printf("Retrying upload %s (attempt %d/%d) after %v\n",
                filename, attempt+1, maxRetries+1, waitTime)
            time.Sleep(waitTime)
        }

        // simulate upload work with chance of failure
        err = simulateUpload(filename, attempt)
        if err == nil {
            break // success!
        }

        fmt.Printf("Upload failed for %s: %v\n", filename, err)
    }

    // send results back
    if err != nil {
        results <- fmt.Sprintf("✗ Failed %s after %d attempts: %v", filename, maxRetries+1, err)
    } else {
        results <- fmt.Sprintf("✓ Uploaded %s", filename)
    }

    fmt.Printf("Finished upload: %s (success: %v)\n", filename, err == nil)
}

// simulateUpload simulates an upload that might fail
func simulateUpload(filename string, attempt int) error {
    // simulate work
    time.Sleep(1 * time.Second)

    // simulate failure on first attempt for some files
    if (filename == "file2.txt" || filename == "file4.txt") && attempt < 2 {
        return fmt.Errorf("network timeout")
    }

    return nil // success
}
```

If you run this, you should see that only two files upload at a time due to the semaphore buffer, but all five will
eventually complete before the program exits.

## Why This Pattern Works

The whole setup gives you:

- **Controlled concurrency:** Only N operations at once
- **Automatic queuing:** Extra work waits in line
- **Graceful handling:** No errors when you hit limits, just blocking
- **Clean coordination:** Everything waits for everything else to finish

It's actually quite elegant once you wrap your head around it. Much better than the Python equivalent where you'd
probably end up with a ThreadPoolExecutor and a bunch of boilerplate.

## Final Thoughts

Go's concurrency primitives are pretty well designed for this sort of thing. The channel-based approach feels weird
coming from other languages, but it does force you to think about data flow and coordination in a more explicit way.

Now I just need to remember all this the next time I'm staring at Go code wondering why there are arrows pointing at
random struct definitions.

The key takeaway is: channels are mailboxes, semaphores are bouncers with limited wristbands, and WaitGroups are
attendance trackers. Everything else is just implementation details.

Future me will thank me for writing this down.

Probably.
