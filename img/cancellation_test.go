package img

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/png"
	"io"
	"sync"
	"testing"
	"time"
)

type unreadablePreview struct{ t *testing.T }

func (r unreadablePreview) Read([]byte) (int, error) {
	r.t.Error("canceled resize read input")
	return 0, io.EOF
}

type waitingResizeContext struct {
	context.Context
	entered chan struct{}
	once    sync.Once
}

func (c *waitingResizeContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.entered) })
	return c.Context.Done()
}

func TestResizeCancelsBlockedSemaphore(t *testing.T) {
	svc := New(1)
	if err := svc.sem.Acquire(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	var release sync.Once
	defer release.Do(func() { svc.sem.Release(1) })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	observed := &waitingResizeContext{Context: ctx, entered: make(chan struct{})}
	done := make(chan error, 1)
	go func() { done <- svc.Resize(observed, unreadablePreview{t}, 1, 1, io.Discard) }()
	<-observed.entered
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Resize = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Resize waited for held semaphore after cancellation")
	}
	release.Do(func() { svc.sem.Release(1) })
	var input bytes.Buffer
	if err := png.Encode(&input, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	if err := svc.Resize(context.Background(), &input, 1, 1, io.Discard); err != nil {
		t.Fatalf("Resize after canceled waiter = %v", err)
	}
}
