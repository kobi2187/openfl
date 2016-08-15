package openfl._internal.renderer.console;
import openfl._internal.renderer.DrawCommandType;
#if lime_console


import cpp.vm.WeakRef;
import cpp.Int8;
import cpp.UInt8;
import cpp.Float32;
import lime.graphics.console.IndexBuffer;
import lime.graphics.console.PointerUtil;
import lime.graphics.console.Primitive;
import lime.graphics.console.RenderState;
import lime.graphics.console.Shader;
import lime.graphics.console.Texture;
import lime.graphics.console.TextureData;
import lime.graphics.console.TextureFilter;
import lime.graphics.console.TextureFormat;
import lime.graphics.console.VertexDecl;
import lime.graphics.console.VertexBuffer;
import lime.graphics.ConsoleRenderContext;
import lime.graphics.Image;
import lime.math.Matrix4;
import lime.text.Glyph;
import lime.text.TextLayout;
import openfl._internal.renderer.cairo.CairoTextField;
import openfl._internal.renderer.AbstractRenderer;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.BlendMode;
import openfl.display.CapsStyle;
import openfl.display.DisplayObject;
import openfl.display.DisplayObjectContainer;
import openfl.display.Graphics;
import openfl.display.JointStyle;
import openfl.display.LineScaleMode;
import openfl.display.Shape;
import openfl.display.Sprite;
import openfl.display.Stage;
import openfl.display.Tilesheet;
import openfl.geom.Matrix;
import openfl.geom.Point;
import openfl.geom.Rectangle;
import openfl.text.Font;
import openfl.text.TextField;
import openfl.text.TextFieldAutoSize;
import openfl.text.TextFormat;
import openfl.text.TextFormatAlign;


@:access(openfl.display.Bitmap)
@:access(openfl.display.BitmapData)
@:access(openfl.display.DisplayObject)
@:access(openfl.display.DisplayObjectContainer)
@:access(openfl.display.Graphics)
@:access(openfl.display.Sprite)
@:access(openfl.display.Stage)
@:access(openfl.display.Tilesheet)
@:access(openfl.geom.Rectangle)


class ConsoleRenderer extends AbstractRenderer {
	

	private var ctx:ConsoleRenderContext;

	private var defaultShader:Shader;
	private var fillShader:Shader;

	private var textureBitmaps = new Array<WeakRef<BitmapData>> ();
	private var textures = new Array<Texture> ();

	private var scissorRect:Array<Float32> = [0, 0, 0, 0];
	private var viewProj:Matrix4;
	private var transform:Matrix4;

	private var hasFill = false;
	private var fillBitmap:BitmapData = null;
	private var fillBitmapMatrix:Matrix = null;
	private var fillBitmapRepeat:Bool = false;
	private var fillBitmapSmooth:Bool = false;
	private var fillColor:Array<Float32> = [1, 1, 1, 1];

	private var hasStroke = false;
	private var lineBitmap:BitmapData = null;
	private var lineBitmapMatrix:Matrix = null;
	private var lineBitmapRepeat:Bool = false;
	private var lineBitmapSmooth:Bool = false;
	private var lineThickness = 0.0;
	private var lineColor:Array<Float32> = [1, 1, 1, 1];
	private var lineAlpha = 1.0;
	private var lineScaleMode = LineScaleMode.NORMAL;
	private var lineCaps = CapsStyle.ROUND;
	private var lineJoints = JointStyle.ROUND;
	private var lineMiter = 3.0;

	private var whiteTexture:Texture;

	private var points = new Array<Float32> ();

	private var blendMode:BlendMode = NORMAL;
	private var clipRect:Rectangle = null;

	#if !console_pc
	private static var pixelOffsetX:Float = 0.0;
	private static var pixelOffsetY:Float = 0.0;
	#else
	// DirectX 9 texture sampling offset
	private static var pixelOffsetX:Float = 0.5;
	private static var pixelOffsetY:Float = 0.5;
	#end

	
	public function new (width:Int, height:Int, ctx:ConsoleRenderContext) {

		this.ctx = ctx;
		
		super (width, height);
		
		this.width = width;
		this.height = height;

		defaultShader = ctx.lookupShader ("openfl_default");
		fillShader = ctx.lookupShader ("openfl_fill");

		
		var white:cpp.UInt32 = 0xffffffff;
		whiteTexture = ctx.createTexture (
			TextureFormat.ARGB,
			1, 1,
			cpp.Pointer.addressOf (white).reinterpret ()
		);

	}


	public function destroy ():Void {

		for (tex in textures) {
			ctx.destroyTexture (tex);
		}

		textures = null;

	}
	
	
	public override function render (stage:Stage):Void {

		viewProj = Matrix4.createOrtho (
			0 + pixelOffsetX,
			width + pixelOffsetX,
			height + pixelOffsetY,
			0 + pixelOffsetY,
			-1, 1
		);

		ctx.setViewport (0, 0, width, height);
		scissorRect[0] = 0.0;
		scissorRect[1] = 0.0;
		scissorRect[2] = width;
		scissorRect[3] = height;

		if (stage.__clearBeforeRender) {

			ctx.clear (
				Std.int (stage.__colorSplit[0] * 0xff),
				Std.int (stage.__colorSplit[1] * 0xff),
				Std.int (stage.__colorSplit[2] * 0xff),
				0xff
			);

		}

		ctx.setRasterizerState (CULLNONE_SOLID);
		ctx.setDepthStencilState (DEPTHTESTOFF_DEPTHWRITEOFF_STENCILOFF);

		blendMode = NORMAL;
		setBlendState (blendMode);

		renderDisplayObject (stage);

		collectTextures ();

	}


	public function setBlendState (b:BlendMode):Void {

		#if !final
		switch (b) {
			case NORMAL, ADD, MULTIPLY:
			default:
				trace ('unsupported blend mode: $b');
		}
		#end

		// TODO(james4k): premultiplied alpha
		ctx.setBlendState (switch (b) {
			case ADD:       SRCALPHA_ONE_ONE_ZERO_RGB;
			case MULTIPLY:  DESTCOLOR_INVSRCALPHA_ONE_ZERO_RGB;
			default:        SRCALPHA_INVSRCALPHA_ONE_ZERO_RGB;
		});

	}


	public override function resize (width:Int, height:Int):Void {

		super.resize (width, height);

		this.width = width;
		this.height = height;

	}

	
	private function renderDisplayObject (object:DisplayObject) {

		if (!object.__renderable || object.__worldAlpha <= 0) {
			return;
		}

		var prevClipRect = clipRect;
		if (object.scrollRect != null) {
			clipRect = new Rectangle (
				object.scrollRect.x,
				object.scrollRect.y,
				object.scrollRect.width,
				object.scrollRect.height
			);
			clipRect.__transform (clipRect, object.__getWorldTransform ());
			if (prevClipRect != null) {
				clipRect = clipRect.intersection(prevClipRect);
			}
		}

		var prevBlendMode = blendMode;
		var objBlendMode:BlendMode = (object.blendMode == null) ? NORMAL : object.blendMode;
		if (objBlendMode != blendMode) {
			blendMode = objBlendMode;
			setBlendState(objBlendMode);
		}

		if (Std.is (object, DisplayObjectContainer)) {

			renderDisplayObjectContainer (cast (object));

		} else if (Std.is (object, Bitmap)) {

			var b:Bitmap = cast (object);
			if (b.bitmapData != null) {
				drawBitmapData (b, b.bitmapData, b.smoothing);
			}

		} else if (Std.is (object, Shape)) {

			renderShape_ (cast (object));

		} else if (Std.is (object, TextField)) {

			renderTextField (cast (object));

		}

		if (object.scrollRect != null) {
			clipRect = prevClipRect;	
		}
		blendMode = prevBlendMode;

	}


	private function renderDisplayObjectContainer (object:DisplayObjectContainer) {

		if (Std.is (object, Sprite)) {

			renderSprite (cast (object));
		}

		for (child in object.__children) {

			renderDisplayObject (child);

		}

		// clean up resources for off-displaylist objects
		if (object.__removedChildren.length > 0) {

			for (orphan in object.__removedChildren) {
				if (orphan.stage == null) {
					orphan.__cleanup ();
				}
			}

			object.__removedChildren = new Array<DisplayObject> ();

		}

	}


	private function setObjectTransform (object:DisplayObject) {

		object.__getWorldTransform ();
		var matrix = object.__worldTransform;
		transform = Matrix4.createABCD (
			matrix.a,
			matrix.b,
			matrix.c,
			matrix.d,
			matrix.tx,
			matrix.ty
		);

	}


	// transientIndexBuffer returns an IndexBuffer that is only valid for the frame
	private inline function transientIndexBuffer (indexCount:Int):IndexBuffer {
 
		return ctx.transientIndexBuffer (indexCount);

	}


	// transientVertexBuffer returns a VertexBuffer that is only valid for the frame
	private inline function transientVertexBuffer (decl:VertexDecl, vertexCount:Int):VertexBuffer {

		return ctx.transientVertexBuffer (decl, vertexCount);

	}


	private function collectTextures ():Void {

		var i = 0;

		while (i < textureBitmaps.length) {

			if (textureBitmaps[i].get () == null) {

				ctx.destroyTexture (textures[i]);

				if (i == textureBitmaps.length - 1) {
					textureBitmaps.pop ();
					textures.pop ();
				} else {
					textureBitmaps[i] = textureBitmaps.pop ();
					textures[i] = textures.pop ();
				}

				continue;

			}

			i++;

		}

	}


	private function bitmapDataTexture (bitmap:BitmapData):Texture {

		if (bitmap.__consoleTexture.valid) {

			var image = bitmap.image;
			var t = bitmap.__consoleTexture;

			if (image.dirty && image.buffer.data != null) {

				t.updateFromRGBA (
					cast (cpp.Pointer.arrayElem (image.buffer.data.buffer.getData (), 0))
				);

				image.dirty = false;

			}

			return bitmap.__consoleTexture;

		}

		var image = bitmap.image;
		var texture = ctx.createTexture (
			TextureFormat.ARGB,
			image.buffer.width,
			image.buffer.height,
			null
		);

		if (image.buffer.data != null) {

			texture.updateFromRGBA (
				cast (cpp.Pointer.arrayElem (image.buffer.data.buffer.getData (), 0))
			);

		}

		image.dirty = false;

		bitmap.__consoleTexture = texture;
		textureBitmaps.push (new WeakRef (bitmap));
		textures.push (texture);

		return texture;

	}


	private function beginClipRect ():Void {

		if (clipRect == null) {
			return;
		}

		var viewport = new Rectangle (0, 0, this.width, this.height);
		viewport = viewport.intersection (clipRect);

		viewProj = Matrix4.createOrtho (
			Math.floor (viewport.x) + pixelOffsetX,
			Math.floor (viewport.x) + Math.ceil (viewport.width) + pixelOffsetX,
			Math.floor (viewport.y) + Math.ceil (viewport.height) + pixelOffsetY,
			Math.floor (viewport.y) + pixelOffsetY,
			-1, 1
		);

		ctx.setViewport (
			cast (viewport.x),
			cast (viewport.y),
			cast (Math.ceil (viewport.width)),
			cast (Math.ceil (viewport.height))
		);
		scissorRect[0] = viewport.x;
		scissorRect[1] = viewport.y;
		scissorRect[2] = viewport.x + viewport.width;
		scissorRect[3] = viewport.y + viewport.height;

	}


	private function endClipRect ():Void {

		if (clipRect == null) {
			return;
		}

		viewProj = Matrix4.createOrtho (
			0 + pixelOffsetX,
			this.width + pixelOffsetX,
			this.height + pixelOffsetY,
			0 + pixelOffsetY,
			-1, 1
		);

		ctx.setViewport (0, 0, this.width, this.height);
		scissorRect[0] = 0;
		scissorRect[1] = 0;
		scissorRect[2] = this.width;
		scissorRect[3] = this.height;

	}


	private function drawBitmapData (object:DisplayObject, bitmap:BitmapData, smoothing:Bool) {

		beginClipRect ();

		setObjectTransform (object);
		transform.append (viewProj);
		transform.transpose ();

		var w = bitmap.width;
		var h = bitmap.height;
		var color:Array<cpp.Float32> = [1, 1, 1, object.__worldAlpha];

		var vertexBuffer = transientVertexBuffer (VertexDecl.PositionTexcoordColor, 4);
		var out = vertexBuffer.lock ();
		out.vec3 (0, 0, 0);
		out.vec2 (0, 0);
		out.color(0xff, 0xff, 0xff, 0xff);
		out.vec3 (0, h, 0);
		out.vec2 (0, 1);
		out.color(0xff, 0xff, 0xff, 0xff);
		out.vec3 (w, 0, 0);
		out.vec2 (1, 0);
		out.color(0xff, 0xff, 0xff, 0xff);
		out.vec3 (w, h, 0);
		out.vec2 (1, 1);
		out.color(0xff, 0xff, 0xff, 0xff);
		vertexBuffer.unlock ();

		var texture = bitmapDataTexture (bitmap);

		ctx.bindShader (defaultShader);
		ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
		ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
		ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (color, 0), 1);
		ctx.setVertexSource (vertexBuffer);
		ctx.setTexture (0, texture);
		ctx.setTextureAddressMode (0, Clamp, Clamp);
		if (smoothing) {
			ctx.setTextureFilter (0, TextureFilter.Linear, TextureFilter.Linear);
		} else {
			ctx.setTextureFilter (0, TextureFilter.Nearest, TextureFilter.Nearest);
		}
		ctx.draw (Primitive.TriangleStrip, 0, 2);

		endClipRect ();

	}


	private function renderShape_ (shape:Shape) {

		var graphics = shape.__graphics;
		//var dirty = graphics.__dirty;
		if (graphics.__commands.length == 0) {
			return;
		}

		drawNaive (shape, graphics);

	}


	private function renderSprite (sprite:Sprite) {

		if (sprite.__graphics == null) {
			return;
		}

		draw (sprite);

	}
	
	
	private function renderTextField (tf:TextField) {
		
		CairoTextField.render (tf, null);

		if (tf.__graphics == null || tf.__graphics.__bitmap == null) {
			return;
		}

		var smoothing = false;
		drawBitmapData (tf, tf.__graphics.__bitmap, smoothing);

	}


	private function draw (object:DisplayObject) {

		var graphics = object.__graphics;
		var dirty = graphics.__dirty;
		if (graphics.__commands.length == 0) {
			return;
		}

		drawNaive (object, graphics);

/*
		if (dirty) {

			//update (object, graphics);

		}

		if (object.cacheAsBitmap) {

			trace ("not implemented");

		} else {
			
			//submit ();

		}
*/

	}


	private function closePath (object:DisplayObject) {

		drawFill (object);
		drawStroke (object);

		cpp.NativeArray.setSize (points, 0);

	}

	
	// div divides an integer by an integer using integer math.
	// Normally in haxe, Int divided by Int returns Float. Can't seem to be
	// avoided even with cast() or Std.int()
	private inline function div (a:Int, b:Int):Int {

		return untyped __cpp__ ("{0} / {1}", a, b);

	}




	private function drawFill (object:DisplayObject) {

		// need minimum of 3 points
		if (!hasFill || points.length < 6) {
			return;
		}

		//var triangles = new Array<Int> ();
		//PolyK.triangulate (triangles, points);

		setObjectTransform (object);
		transform.append (viewProj);
		transform.transpose ();

		var vertexCount = div (points.length, 2);
		var indexCount = (vertexCount - 2) * 3;

		var vertexBuffer = transientVertexBuffer (VertexDecl.Position, vertexCount);	
		var indexBuffer = transientIndexBuffer (indexCount);

		var out = vertexBuffer.lock ();
		for (i in 0...vertexCount) {
			out.vec3 (points[i*2 + 0], points[i*2 + 1], 0);
		}
		vertexBuffer.unlock ();

		var unsafeIndices = indexBuffer.lock ();
		for (i in 0...vertexCount-2) {
			unsafeIndices[i*3 + 0] = 0;
			unsafeIndices[i*3 + 1] = i+1;
			unsafeIndices[i*3 + 2] = i+2;
		}
		indexBuffer.unlock ();

		ctx.bindShader (fillShader);
		ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
		ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
		ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
		ctx.setVertexSource (vertexBuffer);
		//ctx.draw (Primitive.Triangle, 0, vertexCount - 2);
		ctx.setIndexSource (indexBuffer);
		ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, div (indexCount, 3));

	}



	private function drawStroke (object:DisplayObject) {

		var numPoints = Std.int (points.length / 2);
		if (!hasStroke || numPoints < 2) {
			return;
		}

		// TODO(james4k): complex tesselation like this could easily go into a
		// background job. maybe do so if expected vertices is greater than 64 or
		// something. doubt we have any games that need this yet, though. think
		// about this when the renderer does more shape tesselation.
		
		// TODO(james4k): if lines overlap, may be visible overdraw if lines
		// are transparent. not clear if there is a cheap solution.

		// TODO(james4k): closed paths to form rectangles/shapes
		// TODO(james4k): bevel/miter joints
		// TODO(james4k): square/butt caps

		setObjectTransform (object);
		transform.append (viewProj);
		transform.transpose ();

		// TODO(james4k): closed paths should form a joint, and have no caps
		var numSegments = numPoints - 1;
		var numCaps = 2;
		var numJoints = numPoints - numCaps;

		// TODO(james4k): prealloc size should be ConsoleLineTesselator's jurisdiction.
		// also, these overestimate a bit. at least as of May 14th, 2016.
		var vertexCount = numSegments * 4;
		vertexCount += numCaps; // for now just 1 additional vertex for rounded cap
		vertexCount += numJoints; // for now just 1 additional vertex for rounded joint
		var indexCount = numSegments * 6; // 2 triangles per segment
		indexCount += numCaps * 3; // 1 triangle per cap
		indexCount += numJoints * 12; // 4 triangles per joint

		var vertexBuffer = transientVertexBuffer (VertexDecl.PositionTexcoordColor, vertexCount);	
		var indexBuffer = transientIndexBuffer (indexCount);
		var texture = if (lineBitmap != null) {
			bitmapDataTexture (lineBitmap);
		} else {
			whiteTexture;
		}
		var bitmapMatrix:Matrix = new Matrix ();
		if (lineBitmap != null) {
			if (lineBitmapMatrix != null) {
				bitmapMatrix.copyFrom (lineBitmapMatrix);
				bitmapMatrix.invert ();
			}
			bitmapMatrix.scale (1.0 / lineBitmap.width, 1.0 / lineBitmap.height);
		}

		var vertices = vertexBuffer.lock ();
		var unsafeIndices = indexBuffer.lock ();

		var radius = lineThickness * 0.5;
		var line = new ConsoleLineTesselator (vertices, unsafeIndices, radius, bitmapMatrix);

		line.capRound (
			points[0], points[1],
			points[2], points[3]
		);
		for (i in 1...numPoints-1) {
			line.jointRound (
				points[i*2+0], points[i*2+1],
				points[i*2+2], points[i*2+3]
			);
		}
		line.capRound (
			points[points.length-2], points[points.length-1], 0, 0
		);

		#if debug
		if (vertexCount < line.vertexCount || indexCount < line.indexCount) {
			throw "overflowed vertex buffer or index buffer";
		}
		#end
		vertexCount = line.vertexCount;
		indexCount = line.indexCount;
		vertexBuffer.unlock ();
		indexBuffer.unlock ();

		ctx.bindShader (defaultShader);
		ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
		ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
		ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (lineColor, 0), 1);
		ctx.setVertexSource (vertexBuffer);
		ctx.setIndexSource (indexBuffer);
		ctx.setTexture (0, texture);
		if (lineBitmapRepeat) {
			ctx.setTextureAddressMode (0, Wrap, Wrap);
		} else {
			ctx.setTextureAddressMode (0, Clamp, Clamp);
		}
		if (lineBitmapSmooth) {
			ctx.setTextureFilter (0, TextureFilter.Linear, TextureFilter.Linear);
		} else {
			ctx.setTextureFilter (0, TextureFilter.Nearest, TextureFilter.Nearest);
		}
		ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, div (indexCount, 3));

	}


	private function drawNaive (object:DisplayObject, graphics:Graphics) {

		graphics.__dirty = false;

		hasFill = false;
		hasStroke = false;
		fillColor[0] = 1.0;
		fillColor[1] = 1.0;
		fillColor[2] = 1.0;
		fillColor[3] = object.__worldAlpha;

		// TODO(james4k): warn on unimplemented WindingRules

		beginClipRect ();

		var r = new DrawCommandReader (graphics.__commands);

		for (type in graphics.__commands.types) {

			switch (type) {

				//case BeginBitmapFill (bitmap, matrix, repeat, smooth):
				case BEGIN_BITMAP_FILL:

					var cmd = r.readBeginBitmapFill ();

					hasFill = true;
					fillBitmap = cmd.bitmap;
					fillBitmapMatrix = cmd.matrix;
					fillBitmapRepeat = cmd.repeat;
					fillBitmapSmooth = cmd.smooth;
					fillColor[0] = 1.0;
					fillColor[1] = 1.0;
					fillColor[2] = 1.0;
					fillColor[3] = object.__worldAlpha;

				//case BeginFill (rgb, alpha):
				case BEGIN_FILL:

					// TODO(james4k): color transform. no sense doing that in shader for fill, right?

					var cmd = r.readBeginFill ();

					hasFill = true;
					fillBitmap = null;
					fillColor[0] = ((cmd.color >> 16) & 0xFF) / 255.0;
					fillColor[1] = ((cmd.color >> 8) & 0xFF) / 255.0;
					fillColor[2] = ((cmd.color >> 0) & 0xFF) / 255.0;
					fillColor[3] = cmd.alpha * object.__worldAlpha;

				// LineStyle (thickness:Null<Float>, color:Null<Int>, alpha:Null<Float>, pixelHinting:Null<Bool>,
				//            scaleMode:LineScaleMode, caps:CapsStyle, joints:JointStyle, miterLimit:Null<Float>);
				//case LineStyle (thickness, color, alpha, pixelHinting, scaleMode, caps, joints, miterLimit):
				case LINE_STYLE:

					//closePath (object);

					var cmd = r.readLineStyle ();

					if (cmd.thickness == null) {
						hasStroke = false;
						continue;
					}

					hasStroke = true;

					lineThickness = cmd.thickness;
					lineBitmap = null;
					lineColor[0] = ((cmd.color >> 16) & 0xFF) / 255.0;
					lineColor[1] = ((cmd.color >> 8) & 0xFF) / 255.0;
					lineColor[2] = ((cmd.color >> 0) & 0xFF) / 255.0;
					lineColor[3] = cmd.alpha * object.__worldAlpha;
					lineAlpha = cmd.alpha;
					lineScaleMode = cmd.scaleMode;
					lineCaps = cmd.caps != null ? cmd.caps : ROUND;
					lineJoints = cmd.joints != null ? cmd.joints : ROUND;
					lineMiter = cmd.miterLimit;
					// TODO(james4k): pixelHinting

					if (lineScaleMode != NORMAL ||
					    lineCaps != ROUND ||
					    lineJoints != ROUND 
					) {
						trace ("unsupported lineStyle");
					}
					
				case LINE_BITMAP_STYLE:

					var cmd = r.readLineBitmapStyle ();

					lineBitmap = cmd.bitmap;
					lineBitmapMatrix = cmd.matrix;
					lineBitmapRepeat = cmd.repeat;
					lineBitmapSmooth = cmd.smooth;

				//case LineTo (x, y):
				case LINE_TO:

					var cmd = r.readLineTo ();

					points.push (cmd.x);
					points.push (cmd.y);

				//case MoveTo (x, y):
				case MOVE_TO:

					var cmd = r.readMoveTo ();

					closePath (object);

					points.push (cmd.x);
					points.push (cmd.y);

				//case EndFill:
				case END_FILL:

					var cmd = r.readEndFill ();

					closePath (object);

					hasFill = false;
					hasStroke = false;
					fillBitmap = null;
					fillColor[0] = 1.0;
					fillColor[1] = 1.0;
					fillColor[2] = 1.0;
					fillColor[3] = object.__worldAlpha;

				//case DrawCircle (x, y, radius):
				case DRAW_CIRCLE:

					// TODO(james4k): replace with 2? curveTo calls

					var cmd = r.readDrawCircle ();

					drawEllipse (object, cmd.x, cmd.y, cmd.radius, cmd.radius);

				//case DrawEllipse (x, y, width, height):
				case DRAW_ELLIPSE:

					// TODO(james4k): replace with 2? curveTo calls

					var cmd = r.readDrawEllipse ();

					drawEllipse (object, cmd.x + cmd.width*0.5, cmd.y + cmd.height*0.5, cmd.width*0.5, cmd.height*0.5);

				//case DrawRect (x, y, width, height):
				case DRAW_RECT:

					var cmd = r.readDrawRect ();

					if (!hasFill) {
						// TODO(james4k): stroke
						trace ("unsupported DrawRect");
						continue;
					}

					if (fillBitmap != null) {

						setObjectTransform (object);
						transform.append (viewProj);
						transform.transpose ();

						var m:Matrix = new Matrix ();
						if (fillBitmap != null) {
							if (fillBitmapMatrix != null) {
								m.copyFrom(fillBitmapMatrix);
								m.invert();
							}
							m.scale (1.0 / fillBitmap.width, 1.0 / fillBitmap.height);
						}

						var w = cmd.width;
						var h = cmd.height;
						var color:Array<cpp.Float32> = [1, 1, 1, object.__worldAlpha];

						var vertexBuffer = transientVertexBuffer (VertexDecl.PositionTexcoordColor, 4);
						var out = vertexBuffer.lock ();
						out.vec3 (cmd.x, cmd.y, 0);
						out.vec2 ((cmd.x)*m.a + (cmd.y)*m.c + m.tx, (cmd.x)*m.b + (cmd.y)*m.d + m.ty);
						out.color(0xff, 0xff, 0xff, 0xff);
						out.vec3 (cmd.x, cmd.y + h, 0);
						out.vec2 ((cmd.x)*m.a + (cmd.y+h)*m.c + m.tx, (cmd.x)*m.b + (cmd.y+h)*m.d + m.ty);
						out.color(0xff, 0xff, 0xff, 0xff);
						out.vec3 (cmd.x + w, cmd.y, 0);
						out.vec2 ((cmd.x+w)*m.a + (cmd.y)*m.c + m.tx, (cmd.x+w)*m.b + (cmd.y)*m.d + m.ty);
						out.color(0xff, 0xff, 0xff, 0xff);
						out.vec3 (cmd.x + w, cmd.y + h, 0);
						out.vec2 ((cmd.x+w)*m.a + (cmd.y+h)*m.c + m.tx, (cmd.x+w)*m.b + (cmd.y+h)*m.d + m.ty);
						out.color(0xff, 0xff, 0xff, 0xff);
						vertexBuffer.unlock ();

						var texture = bitmapDataTexture (fillBitmap);

						ctx.bindShader (defaultShader);
						ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
						ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
						ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (color, 0), 1);
						ctx.setVertexSource (vertexBuffer);
						ctx.setTexture (0, texture);
						ctx.setTextureAddressMode (0, Clamp, Clamp);
						if (fillBitmapRepeat) {
							ctx.setTextureAddressMode (0, Wrap, Wrap);
						} else {
							ctx.setTextureAddressMode (0, Clamp, Clamp);
						}
						if (fillBitmapSmooth) {
							ctx.setTextureFilter (0, TextureFilter.Linear, TextureFilter.Linear);
						} else {
							ctx.setTextureFilter (0, TextureFilter.Nearest, TextureFilter.Nearest);
						}
						ctx.draw (Primitive.TriangleStrip, 0, 2);

					} else {

						// TODO(james4k): replace moveTo/lineTo calls

						setObjectTransform (object);
						transform.append (viewProj);
						transform.transpose ();

						var vertexBuffer = transientVertexBuffer (VertexDecl.Position, 4);	
						var out = vertexBuffer.lock ();
						out.vec3 (cmd.x, cmd.y, 0);
						out.vec3 (cmd.x, cmd.y + cmd.height, 0);
						out.vec3 (cmd.x + cmd.width, cmd.y, 0);
						out.vec3 (cmd.x + cmd.width, cmd.y + cmd.height, 0);
						vertexBuffer.unlock ();

						ctx.bindShader (fillShader);
						ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
						ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
						ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
						ctx.setVertexSource (vertexBuffer);
						ctx.draw (Primitive.TriangleStrip, 0, 2);

					}

				//case DrawRoundRect (x, y, width, height, rx, ry):
				case DRAW_ROUND_RECT:

					var cmd = r.readDrawRoundRect ();

					if (!hasFill || fillBitmap != null) {
						// TODO(james4k): fillBitmap, stroke
						trace ("unsupported DrawRoundRect");
						continue;
					}

					// TODO(james4k): replace with lineTo/curveTo calls

					var rx = cmd.ellipseWidth * 1.0;
					var ry = cmd.ellipseHeight * 1.0;

					if (ry == -1) ry = rx;
					
					rx *= 0.5;
					ry *= 0.5;
					
					if (rx > cmd.width / 2) rx = cmd.width / 2;
					if (ry > cmd.height / 2) ry = cmd.height / 2;

					var points = new Array<Float> ();
					GraphicsPaths.roundRectangle (points, cmd.x, cmd.y, cmd.width, cmd.height, rx, ry);

					if (hasFill) {

						var triangles = new Array<Int> ();
						PolyK.triangulate (triangles, points);

						if (triangles.length > 0) {

							setObjectTransform (object);
							transform.append (viewProj);
							transform.transpose ();

							var vertexCount = div (points.length, 2);
							var indexCount = triangles.length;

							var vertexBuffer = transientVertexBuffer (VertexDecl.Position, vertexCount);	
							var indexBuffer = transientIndexBuffer (indexCount);

							var out = vertexBuffer.lock ();
							for (i in 0...div (points.length, 2)) {
								out.vec3 (points[i*2], points[i*2 + 1], 0);
							}
							vertexBuffer.unlock ();

							var unsafeIndices = indexBuffer.lock ();
							for (i in 0...triangles.length) {
								unsafeIndices[i] = triangles[i];
							}
							indexBuffer.unlock ();

							ctx.bindShader (fillShader);
							ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
							ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
							ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
							ctx.setVertexSource (vertexBuffer);
							ctx.setIndexSource (indexBuffer);
							ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, div (triangles.length, 3));

						}

					}

				//case DrawTiles (sheet, tileData, smooth, flags, count):
				case DRAW_TILES:

					var cmd = r.readDrawTiles ();

					var useScale = (cmd.flags & Tilesheet.TILE_SCALE) != 0;
					var useRotation = (cmd.flags & Tilesheet.TILE_ROTATION) != 0;
					var useTransform = (cmd.flags & Tilesheet.TILE_TRANS_2x2) != 0;
					var useRGB = (cmd.flags & Tilesheet.TILE_RGB) != 0;
					var useAlpha = (cmd.flags & Tilesheet.TILE_ALPHA) != 0;
					var useRect = (cmd.flags & Tilesheet.TILE_RECT) != 0;
					var useOrigin = (cmd.flags & Tilesheet.TILE_ORIGIN) != 0;

					var blendMode:BlendMode = switch(cmd.flags & 0xF0000) {
						case Tilesheet.TILE_BLEND_ADD:		ADD;
						case Tilesheet.TILE_BLEND_MULTIPLY:	MULTIPLY;
						case Tilesheet.TILE_BLEND_SCREEN:	SCREEN;
						case _: switch(cmd.flags & 0xF00000) {
							case Tilesheet.TILE_BLEND_DARKEN:         DARKEN;
							case Tilesheet.TILE_BLEND_LIGHTEN:        LIGHTEN;
							case Tilesheet.TILE_BLEND_OVERLAY:        OVERLAY;
							case Tilesheet.TILE_BLEND_HARDLIGHT:      HARDLIGHT;
							case _: switch(cmd.flags & 0xF000000) {
								case Tilesheet.TILE_BLEND_DIFFERENCE: DIFFERENCE;
								case Tilesheet.TILE_BLEND_INVERT:     INVERT;
								case _:                               NORMAL;
							}
						}
					};

					if (useTransform) {
						useScale = false;
						useRotation = false;
					}

					var scaleIndex = 0;
					var rotationIndex = 0;
					var transformIndex = 0;
					var rgbIndex = 0;
					var alphaIndex = 0;

					var stride = 3;
					if (useRect) {
						stride = useOrigin ? 8 : 6;
					}
					if (useScale) {
						scaleIndex = stride;
						stride += 1;
					}
					if (useRotation) {
						rotationIndex = stride;
						stride += 1;
					}
					if (useTransform) {
						transformIndex = stride;
						stride += 4;
					}
					if (useRGB) {
						rgbIndex = stride;
						stride += 3;
					}
					if (useAlpha) {
						alphaIndex = stride;
						stride += 1;
					}

					var totalCount = cmd.tileData.length;
					if (cmd.count >= 0 && totalCount > cmd.count) {
						totalCount = cmd.count;
					}
					var itemCount = div (totalCount, stride);
					if (itemCount <= 0) {
						continue;
					}

					var tileID = -1;
					var rect:Rectangle = cmd.sheet.__rectTile;
					var tileUV:Rectangle = cmd.sheet.__rectUV;
					var center:Point = cmd.sheet.__point;

					var skippedItemCount = 0;
					var vertexCount = itemCount * 4;
					var vertexBuffer = transientVertexBuffer (VertexDecl.PositionTexcoordColor, vertexCount);	
					var out = vertexBuffer.lock ();

					for (itemIndex in 0...itemCount) {

						var index = itemIndex * stride;

						var x = cmd.tileData[index + 0];
						var y = cmd.tileData[index + 1];

						if (useRect) {

							tileID = -1;

							rect.x = cmd.tileData[index + 2];
							rect.y = cmd.tileData[index + 3];
							rect.width = cmd.tileData[index + 4];
							rect.height = cmd.tileData[index + 5];
							
							if (useOrigin) {
								center.x = cmd.tileData[index + 6];
								center.y = cmd.tileData[index + 7];
							} else {
								center.setTo(0, 0);
							}
							
							tileUV.setTo(
								rect.left / cmd.sheet.__bitmap.width,
								rect.top / cmd.sheet.__bitmap.height,
								rect.right / cmd.sheet.__bitmap.width,
								rect.bottom / cmd.sheet.__bitmap.height
							);

						} else {

							tileID = Std.int (cmd.tileData[index + 2]);
							cmd.sheet.copyTileRect(rect, tileID);	
							cmd.sheet.copyTileCenter(center, tileID);	
							cmd.sheet.copyTileUVs(tileUV, tileID);	

						}

						if (rect == null || rect.width <= 0 || rect.height <= 0 || center == null) {
							skippedItemCount++;
							continue;
						}	

						var alpha = object.__worldAlpha;
						var red:UInt8 = 255, green:UInt8 = 255, blue:UInt8 = 255;
						var scale = 1.0;
						var rotation = 0.0;
						var a = 0.0, b = 0.0, c = 0.0, d = 0.0, tx = 0.0, ty = 0.0;

						if (useRGB) {
							// TODO(james4k): premultiplied alpha?
							red   = Std.int (cmd.tileData[index + rgbIndex + 0] * 255);
							green = Std.int (cmd.tileData[index + rgbIndex + 1] * 255);
							blue  = Std.int (cmd.tileData[index + rgbIndex + 2] * 255);
						}

						if (useAlpha) {
							alpha *= cmd.tileData[index + alphaIndex];	
						}

						if (useScale) {
							scale = cmd.tileData[index + scaleIndex];
						}

						if (useRotation) {
							rotation = cmd.tileData[index + rotationIndex];
						}

						if (useTransform) {
							a = cmd.tileData[index + transformIndex + 0];
							b = cmd.tileData[index + transformIndex + 1];
							c = cmd.tileData[index + transformIndex + 2];
							d = cmd.tileData[index + transformIndex + 3];
						} else {
							a = scale * Math.cos (rotation);
							b = scale * Math.sin (rotation);
							c = -b;
							d = a;
						}

						var tx = x - (center.x * a + center.y * c);
						var ty = y - (center.x * b + center.y * d);

						var w0 = rect.width * 1.0;
						var w1 = 0.0;
						var h0 = rect.height * 1.0;
						var h1 = 0.0;

						// tileUV.width, height are actually x1, y1

						out.vec3 (a*w1 + c*h1 + tx, d*h1 + b*w1 + ty, 0);
						out.vec2 (tileUV.x, tileUV.y);
						out.color (red, green, blue, Std.int(alpha * 0xff));

						out.vec3 (a*w0 + c*h1 + tx, d*h1 + b*w0 + ty, 0);
						out.vec2 (tileUV.width, tileUV.y);
						out.color (red, green, blue, Std.int(alpha * 0xff));

						out.vec3 (a*w0 + c*h0 + tx, d*h0 + b*w0 + ty, 0);
						out.vec2 (tileUV.width, tileUV.height);
						out.color (red, green, blue, Std.int(alpha * 0xff));

						out.vec3 (a*w1 + c*h0 + tx, d*h0 + b*w1 + ty, 0);
						out.vec2 (tileUV.x, tileUV.height);
						out.color (red, green, blue, Std.int(alpha * 0xff));

					}

					vertexBuffer.unlock ();
					itemCount -= skippedItemCount;
					vertexCount = itemCount * 4;

					var indexBuffer = transientIndexBuffer (itemCount * 6);
					var unsafeIndices = indexBuffer.lock ();
					for (i in 0...itemCount) {
						unsafeIndices[i*6 + 0] = i*4 + 0;
						unsafeIndices[i*6 + 1] = i*4 + 1;
						unsafeIndices[i*6 + 2] = i*4 + 2;
						unsafeIndices[i*6 + 3] = i*4 + 0;
						unsafeIndices[i*6 + 4] = i*4 + 3;
						unsafeIndices[i*6 + 5] = i*4 + 2;
					}
					indexBuffer.unlock ();

					setObjectTransform (object);
					transform.append (viewProj);
					transform.transpose ();

					var texture = bitmapDataTexture (cmd.sheet.__bitmap);

					setBlendState (blendMode);
					ctx.bindShader (defaultShader);
					ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
					ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
					ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
					ctx.setVertexSource (vertexBuffer);
					ctx.setIndexSource (indexBuffer);
					ctx.setTexture (0, texture);
					ctx.setTextureAddressMode (0, Clamp, Clamp);
					if (cmd.smooth) {
						ctx.setTextureFilter (0, TextureFilter.Linear, TextureFilter.Linear);
					} else {
						ctx.setTextureFilter (0, TextureFilter.Nearest, TextureFilter.Nearest);
					}
					ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, itemCount * 2);
					setBlendState (this.blendMode);

				//case DrawTriangles (vertices, indices, uvtData, culling, colors, blendMode):
				case DRAW_TRIANGLES:

					var cmd = r.readDrawTriangles ();

					if (!hasFill || fillBitmap == null) {
						trace ("DrawTriangles without bitmap fill");
						continue;
					}

					if (cmd.vertices.length <= 0 || cmd.indices.length <= 0) {
						continue;
					}

					setObjectTransform (object);
					transform.append (viewProj);
					transform.transpose ();

					var texture = bitmapDataTexture (fillBitmap);

					var cmdVertices = cmd.vertices;
					var cmdIndices = cmd.indices;
					var cmdUvtData = cmd.uvtData;
					var vertexCount = div (cmdVertices.length, 2);
					var vertexBuffer = transientVertexBuffer (VertexDecl.PositionTexcoordColor, vertexCount);	
					var out = vertexBuffer.lock ();
					var i = 0;
					while (i < cmd.vertices.length) {
						out.vec3 (cmdVertices[i], cmdVertices[i+1], 0);
						out.vec2 (cmdUvtData[i], cmdUvtData[i+1]);
						// TODO(james4k): color
						out.color (0xff, 0xff, 0xff, 0xff);
						i += 2;
					}
					vertexBuffer.unlock ();
					
					var indexCount = cmdIndices.length;
					var indexBuffer = transientIndexBuffer (indexCount);
					var unsafeIndices = indexBuffer.lock ();
					for (i in 0...indexCount) {
						unsafeIndices[i] = cmdIndices[i];
					}
					indexBuffer.unlock ();

					ctx.bindShader (defaultShader);
					ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
					ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
					ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
					ctx.setVertexSource (vertexBuffer);
					ctx.setIndexSource (indexBuffer);
					ctx.setTexture (0, texture);
					ctx.setTextureAddressMode (0, Wrap, Wrap);
					if (fillBitmapSmooth) {
						ctx.setTextureFilter (0, TextureFilter.Linear, TextureFilter.Linear);
					} else {
						ctx.setTextureFilter (0, TextureFilter.Nearest, TextureFilter.Nearest);
					}
					ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, div (cmd.indices.length, 3));

				case BEGIN_GRADIENT_FILL:

					r.readBeginGradientFill ();

				case CUBIC_CURVE_TO:

					r.readCubicCurveTo ();

				case CURVE_TO:

					r.readCurveTo ();

				case LINE_GRADIENT_STYLE:

					r.readLineGradientStyle ();

				case OVERRIDE_MATRIX:

					r.readOverrideMatrix ();

				case UNKNOWN:

			}
	
		}

		r.destroy ();

		if (points.length > 0) {
			closePath (object);
		}

		endClipRect ();

	}

	private function drawEllipse (object:DisplayObject, x:Float, y:Float, rx:Float, ry:Float) {

		if (!hasFill || fillBitmap != null) {
			// TODO(james4k): fillBitmap, stroke
			trace ("unsupported drawEllipse");
			return;
		}

		var segments:Int = cast (0.334 * 2 * Math.PI * Math.max (rx, ry));
		var points = new Array<Float> ();
		GraphicsPaths.ellipse (points, x, y, rx, ry, segments);

		if (hasFill) {

			//var triangles = new Array<Int> ();
			//PolyK.triangulate (triangles, points);

			setObjectTransform (object);
			transform.append (viewProj);
			transform.transpose ();

			var vertexCount = div (points.length, 2) + 1;
			var indexCount = (vertexCount - 2) * 3;

			var vertexBuffer = transientVertexBuffer (VertexDecl.Position, vertexCount);	
			var indexBuffer = transientIndexBuffer (indexCount);

			var out = vertexBuffer.lock ();
			out.vec3 (x, y, 0);
			for (i in 0...vertexCount) {
				out.vec3 (points[i*2 + 0], points[i*2 + 1], 0);
			}
			vertexBuffer.unlock ();

			var unsafeIndices = indexBuffer.lock ();
			for (i in 0...vertexCount-2) {
				unsafeIndices[i*3 + 0] = 0;
				unsafeIndices[i*3 + 1] = i+1;
				unsafeIndices[i*3 + 2] = i+2;
			}
			indexBuffer.unlock ();

			ctx.bindShader (fillShader);
			ctx.setPixelShaderConstantF (0, cpp.Pointer.arrayElem (scissorRect, 0), 1);
			ctx.setVertexShaderConstantF (0, PointerUtil.fromMatrix (transform), 4);
			ctx.setVertexShaderConstantF (4, cpp.Pointer.arrayElem (fillColor, 0), 1);
			ctx.setVertexSource (vertexBuffer);
			//ctx.draw (Primitive.Triangle, 0, vertexCount - 2);
			ctx.setIndexSource (indexBuffer);
			ctx.drawIndexed (Primitive.Triangle, vertexCount, 0, div (indexCount, 3));

		}

	}

	
	
}


#else


import lime.graphics.ConsoleRenderContext;
import openfl._internal.renderer.AbstractRenderer;
import openfl.display.Stage;


class ConsoleRenderer extends AbstractRenderer {
	

	public function new (width:Int, height:Int, ctx:ConsoleRenderContext) {
		
		super (width, height);

		throw "ConsoleRenderer not supported";

	}
	
	
	public override function render (stage:Stage):Void {



	}


}

	
#end
